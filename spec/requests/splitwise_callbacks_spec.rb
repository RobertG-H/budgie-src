require "rails_helper"

# Where Splitwise sends the person back to (ADR 0016): the callback checks the state that was sent, keeps nothing on a refusal or a decline, swaps the code for a
# token, and makes the connection and its Account in one database transaction, or reconnects the connection of a login that's there. Splitwise is replaced by
# SplitwiseFake (spec/support/splitwise.rb). The form that sends them there is in splitwise_connections_spec.rb.
RSpec.describe "Splitwise's callback", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:robert) { Splitwise::Person.new(id: "4321", name: "Robert G.") }

  around { |example| travel_to(Time.zone.local(2026, 10, 6, 12)) { example.run } }
  before { sign_in_as budget.user }

  def connect_form(name: "Splitwise", read_from: "2026-10-01")
    { account: { name: name }, bank_connection: { read_from: read_from } }
  end

  # The person submits the form and is sent to Splitwise, which answers with the `state` that was sent along.
  def start_connecting(**form)
    post splitwise_connection_path, params: connect_form(**form)
    expect(response).to have_http_status(:found), "expected a redirect to Splitwise, got #{response.status}"
    state_sent_to_splitwise
  end

  describe "GET /splitwise/callback" do
    before { splitwise.signs_in("good-code", as: robert, token: "its-access-token") }

    it "checks the state, swaps the code for a token, asks who it's for, and makes the connection and its Account, with its Filing rules off" do
      state = start_connecting(name: "My Splitwise", read_from: "2026-09-15")

      expect { get splitwise_callback_path(code: "good-code", state: state) }
        .to change(Budget::BankConnection, :count).by(1).and change(Budget::Account, :count).by(1)

      connection = budget.bank_connections.sole
      account = budget.accounts.sole
      expect(connection).to have_attributes(provider: "splitwise", login_id: "4321", login_name: "Robert G.", access_token: "its-access-token",
        read_from: Date.new(2026, 9, 15), needs_reconnect: false, sync_cursor: nil, synced_at: nil)
      expect(account).to have_attributes(name: "My Splitwise", bank_connection: connection, external_account_id: "4321", files_with_rules: false)
      expect(splitwise.exchanges).to eq([ { code: "good-code", redirect_uri: "http://www.example.com/splitwise/callback" } ])
      expect(splitwise.lookups).to eq([ "its-access-token" ])
      expect(response).to redirect_to(account_path(account))
      expect(flash[:notice]).to eq("Connected Splitwise as Robert G.")
    end

    it "makes them in the current user's budget, never another's" do
      other = create(:budget)
      state = start_connecting

      get splitwise_callback_path(code: "good-code", state: state)

      expect(budget.bank_connections.count).to eq(1)
      expect(other.bank_connections.count).to eq(0)
      expect(other.accounts.count).to eq(0)
    end

    it "makes the connection and the Account in one database transaction, so an Account that can't be made leaves no connection" do
      state = start_connecting
      create(:budget_account, budget: budget, name: "Splitwise") # Made in another tab while the person was at Splitwise.

      expect { get splitwise_callback_path(code: "good-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to redirect_to(new_splitwise_connection_path)
      expect(flash[:alert]).to eq("Splitwise wasn't connected. Name has already been taken. Nothing was kept. Try again.")
    end

    it "keeps the token off the page it lands on, and the code out of the log's params" do
      state = start_connecting

      get splitwise_callback_path(code: "good-code", state: state)

      expect(request.filtered_parameters).to include("code" => "[FILTERED]")
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("its-access-token")
      assert_select "[role=status]", text: "Connected Splitwise as Robert G."
    end

    it "refuses a state that isn't the one that was sent, and keeps nothing, without asking Splitwise for anything" do
      start_connecting

      expect { get splitwise_callback_path(code: "good-code", state: "a-state-nobody-sent") }
        .not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Splitwise wasn't connected, since its sign-in wasn't the one that was started. Nothing was kept. Try again.")
      expect(splitwise.exchanges).to be_empty
      expect(splitwise.lookups).to be_empty
    end

    it "refuses a callback with no state at all" do
      start_connecting

      get splitwise_callback_path(code: "good-code")

      expect(response).to redirect_to(accounts_path)
      expect(splitwise.exchanges).to be_empty
      expect(budget.bank_connections).to be_none
    end

    it "refuses a callback when no sign-in was started, as one that was made up would be" do
      get splitwise_callback_path(code: "good-code", state: "anything")

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Splitwise wasn't connected, since its sign-in wasn't the one that was started. Nothing was kept. Try again.")
      expect(splitwise.exchanges).to be_empty
      expect(budget.bank_connections).to be_none
    end

    it "refuses a sign-in that was started for another budget, such as by someone who has signed out of this browser since" do
      state = start_connecting
      delete session_path
      other = create(:budget)
      sign_in_as other.user

      get splitwise_callback_path(code: "good-code", state: state)

      expect(response).to redirect_to(accounts_path)
      expect(splitwise.exchanges).to be_empty
      expect(Budget::BankConnection.count).to eq(0)
    end

    it "stops accepting a sign-in that was started more than an hour ago, since an abandoned one shouldn't linger" do
      state = start_connecting

      travel 61.minutes # Without a block, since the example is already in one: the surrounding travel_to puts the clock back when it ends.

      expect { get splitwise_callback_path(code: "good-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to redirect_to(accounts_path)
      expect(splitwise.exchanges).to be_empty
    end

    it "still accepts one that's been at Splitwise for a while, within the hour" do
      state = start_connecting

      travel 50.minutes

      get splitwise_callback_path(code: "good-code", state: state)

      expect(flash[:notice]).to eq("Connected Splitwise as Robert G.")
    end

    it "keeps nothing, and doesn't fail, when another request made the Account between the check and the insert" do
      state = start_connecting
      allow_any_instance_of(Budget::Account).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

      expect { get splitwise_callback_path(code: "good-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to redirect_to(new_splitwise_connection_path)
      expect(flash[:alert]).to eq("Splitwise wasn't connected. Another request made it a moment ago. Nothing was kept. Try again.")
    end

    it "can only be used once: the same callback again is refused, and makes nothing more" do
      state = start_connecting
      get splitwise_callback_path(code: "good-code", state: state)

      expect { get splitwise_callback_path(code: "good-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(flash[:alert]).to eq("Splitwise wasn't connected, since its sign-in wasn't the one that was started. Nothing was kept. Try again.")
      expect(splitwise.exchanges.size).to eq(1)
    end

    it "keeps nothing when the person declines at Splitwise, and doesn't ask it for a token" do
      state = start_connecting

      expect { get splitwise_callback_path(error: "access_denied", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to redirect_to(new_splitwise_connection_path)
      expect(flash[:alert]).to eq("Splitwise wasn't connected, since the sign-in was declined. Nothing was kept.")
      expect(splitwise.exchanges).to be_empty
    end

    it "treats a decline with the wrong state as the refusal it is, and a code that's missing as one too" do
      state = start_connecting
      get splitwise_callback_path(error: "access_denied", state: "other")
      expect(flash[:alert]).to start_with("Splitwise wasn't connected, since its sign-in wasn't the one that was started.")

      state = start_connecting
      get splitwise_callback_path(state: state)
      expect(flash[:alert]).to eq("Splitwise wasn't connected, since Splitwise sent no code. Nothing was kept. Try again.")
      expect(splitwise.exchanges).to be_empty
    end

    it "keeps nothing when Splitwise refuses the code, and says so without what it answered" do
      state = start_connecting

      expect { get splitwise_callback_path(code: "a-bad-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to redirect_to(new_splitwise_connection_path)
      expect(flash[:alert]).to eq("Splitwise wasn't connected. Splitwise didn't accept the sign-in (400). Nothing was kept. Try again.")
    end

    it "keeps nothing when Splitwise can't be reached" do
      state = start_connecting
      splitwise.fails_with(Splitwise::Error.new("Splitwise couldn't be reached."))

      expect { get splitwise_callback_path(code: "good-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(flash[:alert]).to eq("Splitwise wasn't connected. Splitwise couldn't be reached. Nothing was kept. Try again.")
    end

    it "keeps nothing when it can't be asked who the token is for" do
      state = start_connecting
      splitwise.revoke("its-access-token")

      expect { get splitwise_callback_path(code: "good-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(flash[:alert]).to eq("Splitwise wasn't connected. Splitwise doesn't accept the token any more. Nothing was kept. Try again.")
    end

    it "never puts the token in a refusal, in a flash or a log, whatever went wrong" do
      state = start_connecting
      splitwise.fails_with(Splitwise::Error.new("Splitwise couldn't be reached."))

      get splitwise_callback_path(code: "good-code", state: state)
      follow_redirect!

      expect(response.body).not_to include("its-access-token")
      expect(response.body).not_to include("good-code")
    end

    context "when the Splitwise login is already connected" do
      let!(:connection) do
        create(:budget_bank_connection, budget: budget, login_id: "4321", login_name: "Rob G.", access_token: "old-token", read_from: Date.new(2026, 8, 1), needs_reconnect: true)
      end
      let!(:account) { create(:budget_account, budget: budget, name: "Splitwise", bank_connection: connection, external_account_id: "4321") }

      it "updates its token and name, clears needs-reconnect, and keeps the Account, its name and what it reads from" do
        state = start_connecting(name: "A different name", read_from: "2026-10-01")

        expect { get splitwise_callback_path(code: "good-code", state: state) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

        expect(connection.reload).to have_attributes(access_token: "its-access-token", login_name: "Robert G.", needs_reconnect: false, read_from: Date.new(2026, 8, 1))
        expect(account.reload.name).to eq("Splitwise")
        expect(response).to redirect_to(account_path(account))
        expect(flash[:notice]).to eq("Reconnected Splitwise as Robert G. It was already connected, so its Account and the date it reads from stay as they are.")
      end

      it "does so for a connection that was disconnected, and keeps the Account's bank transactions and what they were filed as" do
        transaction = create(:budget_bank_transaction, :filed, account: account)
        connection.disconnect!
        state = start_connecting(name: "Another one")

        get splitwise_callback_path(code: "good-code", state: state)

        expect(connection.reload).to be_connected
        expect(account.reload.bank_transactions).to eq([ transaction ])
        expect(transaction.reload).to be_filed
      end

      it "doesn't mind the name it was asked with having been taken since, since it makes no Account" do
        state = start_connecting(name: "Fresh name")
        create(:budget_account, budget: budget, name: "Fresh name")

        get splitwise_callback_path(code: "good-code", state: state)

        expect(flash[:notice]).to start_with("Reconnected Splitwise as Robert G. It was already connected")
      end
    end

    context "when the Splitwise login is a different one from the one connected" do
      let!(:connection) { create(:budget_bank_connection, budget: budget, login_id: "9999", login_name: "Jane D.", access_token: "janes-token") }
      let!(:account) { create(:budget_account, budget: budget, name: "Jane's Splitwise", bank_connection: connection, external_account_id: "9999") }

      it "is a new connection with a new Account, and leaves the other alone" do
        state = start_connecting(name: "Splitwise")

        expect { get splitwise_callback_path(code: "good-code", state: state) }
          .to change(Budget::BankConnection, :count).by(1).and change(Budget::Account, :count).by(1)

        expect(connection.reload).to have_attributes(access_token: "janes-token", login_name: "Jane D.")
        expect(budget.accounts.find_by!(name: "Splitwise").bank_connection).to have_attributes(login_id: "4321")
      end
    end

    context "when another budget has the same Splitwise login connected" do
      it "is still a connection of this budget's own" do
        create(:budget_bank_connection, login_id: "4321", access_token: "someone-elses")
        state = start_connecting

        expect { get splitwise_callback_path(code: "good-code", state: state) }.to change { budget.bank_connections.count }.by(1)

        expect(Budget::BankConnection.where(login_id: "4321").map(&:access_token)).to contain_exactly("someone-elses", "its-access-token")
      end
    end

    it "requires sign-in, and asks Splitwise for nothing without it" do
      state = start_connecting
      delete session_path

      get splitwise_callback_path(code: "good-code", state: state)

      expect(response).to redirect_to(sign_in_path)
      expect(splitwise.exchanges).to be_empty
    end
  end

  describe "a budget's Account made by connecting" do
    it "is an ordinary Account that bank transactions will be filed from, with Filing rules off so every one waits for a person" do
      state = start_connecting
      splitwise.signs_in("good-code", as: robert)
      get splitwise_callback_path(code: "good-code", state: state)

      account = budget.accounts.sole
      get account_path(account)

      expect(response).to have_http_status(:ok)
      expect(account.files_with_rules).to be(false)
      expect(account).to be_synced
    end
  end
end
