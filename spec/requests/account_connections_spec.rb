require "rails_helper"

# What a synced Account is synced from, on its page: Reconnect and Disconnect (ADR 0016). Disconnecting forgets the token and keeps the Account, its
# bank transactions and what they were filed as. Reconnecting the same Splitwise user keeps them too, and a different one is refused here.
RSpec.describe "An Account's connection", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:connection) { create(:budget_bank_connection, budget: budget, login_id: "7654321", login_name: "Robert G.", access_token: "its-token", read_from: Date.new(2026, 10, 1)) }
  let!(:account) { create(:budget_account, :synced, budget: budget, name: "Shared expenses", bank_connection: connection) }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  describe "on the Account's page" do
    it "says what it's synced from, and what it reads from, with Reconnect and Disconnect" do
      get account_path(account)

      expect(response).to have_http_status(:ok)
      expect(visible_text).to include("Synced from Splitwise as Robert G., reading expenses dated from Oct 1, 2026.")
      assert_select "form[action='#{account_connection_path(account)}'][method=post][data-turbo=false]" do
        assert_select "button", text: "Reconnect"
      end
      assert_select "form[action='#{account_connection_path(account)}']" do
        assert_select "input[name=_method][value=delete]"
        assert_select "button", text: "Disconnect"
      end
    end

    it "asks before it disconnects, and says what stays" do
      get account_path(account)

      question = css_select("form[action='#{account_connection_path(account)}'][data-turbo-confirm]").first["data-turbo-confirm"]
      expect(question).to eq("Disconnect Splitwise? Budgie forgets its sign-in and stops syncing. The Account, its bank transactions and what they were filed as stay.")
    end

    it "says when it needs reconnecting, and offers Reconnect and Disconnect" do
      connection.update!(needs_reconnect: true)

      get account_path(account)

      expect(visible_text).to include("Splitwise stopped accepting the sign-in as Robert G., so this Account isn't syncing. Reconnect to start again.")
      assert_select "button", text: "Reconnect"
      assert_select "button", text: "Disconnect"
    end

    it "says when it's disconnected, and offers Reconnect only" do
      connection.disconnect!

      get account_path(account)

      expect(visible_text).to include("Disconnected from Splitwise, so this Account isn't syncing. Its bank transactions stay as they are. Reconnect as Robert G. to start again.")
      assert_select "button", text: "Reconnect"
      assert_select "button", text: "Disconnect", count: 0
    end

    it "offers no Reconnect where Splitwise isn't set up, and still offers Disconnect, which needs nothing from Splitwise" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      get account_path(account)

      assert_select "button", text: "Reconnect", count: 0
      assert_select "button", text: "Disconnect"
    end

    it "never shows the token, or the Splitwise user's id, on its page or its form" do
      [ account_path(account), edit_account_path(account), accounts_path ].each do |path|
        get path

        expect(response.body).not_to include("its-token"), path
        expect(response.body).not_to include("7654321"), path
      end
    end

    it "still says what it's synced from, and offers Reconnect and Disconnect, when the key its token was kept under has been lost" do
      garbage = { "p" => Base64.strict_encode64("not-the-payload"), "h" => { "iv" => Base64.strict_encode64("0123456789ab"), "at" => Base64.strict_encode64("0123456789abcdef") } }.to_json
      Budget::BankConnection.connection.execute(Budget::BankConnection.sanitize_sql_array([ "UPDATE budget_bank_connections SET access_token = ? WHERE id = ?", garbage, connection.id ]))

      get account_path(account)

      expect(response).to have_http_status(:ok)
      expect(visible_text).to include("Synced from Splitwise as Robert G.")
      assert_select "button", text: "Reconnect"
      assert_select "button", text: "Disconnect"
    end

    it "says nothing of a connection for an Account that isn't synced" do
      csv = create(:budget_account, budget: budget, name: "Chequing")

      get account_path(csv)

      expect(visible_text).not_to include("Synced from")
      assert_select "button", text: "Reconnect", count: 0
      assert_select "button", text: "Disconnect", count: 0
    end
  end

  describe "POST /accounts/:account_id/connection (Reconnect)" do
    before { splitwise.signs_in("good-code", as: Splitwise::Person.new(id: "7654321", name: "Rob G."), token: "a-new-token") }

    it "sends the person to Splitwise to sign in again, with a random state and the callback to come back to, and changes nothing yet" do
      expect { post account_connection_path(account) }.not_to change { connection.reload.attributes }

      expect(response.location).to start_with("https://secure.splitwise.com/oauth/authorize?")
      expect(splitwise.authorizations).to eq([ { redirect_uri: "http://www.example.com/splitwise/callback", state: state_sent_to_splitwise } ])
    end

    it "gives the same connection a new token when the same Splitwise user signs in, and keeps the Account, its bank transactions and what they were filed as" do
      filed = create(:budget_bank_transaction, :filed, account: account)
      connection.update!(needs_reconnect: true)
      post account_connection_path(account)

      expect { get splitwise_callback_path(code: "good-code", state: state_sent_to_splitwise) }
        .not_to change { [ Budget::Account.count, Budget::BankConnection.count, Budget::BankTransaction.count ] }

      expect(response).to redirect_to(account_path(account))
      expect(flash[:notice]).to eq("Reconnected Splitwise as Rob G.")
      expect(connection.reload).to have_attributes(access_token: "a-new-token", login_name: "Rob G.", needs_reconnect: false, read_from: Date.new(2026, 10, 1))
      expect(account.reload.bank_transactions).to eq([ filed ])
      expect(filed.reload).to be_filed
    end

    it "does so for a connection that was disconnected" do
      connection.disconnect!
      post account_connection_path(account)

      get splitwise_callback_path(code: "good-code", state: state_sent_to_splitwise)

      expect(connection.reload).to be_connected
      expect(connection.access_token).to eq("a-new-token")
    end

    it "refuses a different Splitwise user, which is for Connect Splitwise on the Accounts page, and changes nothing" do
      splitwise.signs_in("janes-code", as: Splitwise::Person.new(id: "9999", name: "Jane D."), token: "janes-token")
      post account_connection_path(account)

      expect { get splitwise_callback_path(code: "janes-code", state: state_sent_to_splitwise) }
        .not_to change { [ Budget::Account.count, Budget::BankConnection.count, connection.reload.attributes ] }

      expect(response).to redirect_to(account_path(account))
      expect(flash[:alert]).to eq("Splitwise wasn't reconnected. Shared expenses is synced from Splitwise as Robert G., and that isn't who signed in. " \
        "To sync another Splitwise user, use Connect Splitwise on the Accounts page. Nothing was changed. Try again.")
    end

    it "keeps everything as it was when the person declines at Splitwise, and goes back to the Account's page" do
      post account_connection_path(account)

      get splitwise_callback_path(error: "access_denied", state: state_sent_to_splitwise)

      expect(response).to redirect_to(account_path(account))
      expect(flash[:alert]).to eq("Splitwise wasn't reconnected, since the sign-in was declined. Nothing was changed.")
      expect(connection.reload.access_token).to eq("its-token")
    end

    it "refuses a state that isn't the one that was sent" do
      post account_connection_path(account)

      get splitwise_callback_path(code: "good-code", state: "something-else")

      expect(connection.reload.access_token).to eq("its-token")
      expect(splitwise.exchanges).to be_empty
    end

    it "is a 404 for an Account that isn't synced, and another user's Account" do
      csv = create(:budget_account, budget: budget)
      others = create(:budget_account, :synced)

      post account_connection_path(csv)
      expect(response).to have_http_status(:not_found)
      post account_connection_path(others)
      expect(response).to have_http_status(:not_found)
      expect(splitwise.authorizations).to be_empty
    end

    it "isn't done where Splitwise isn't set up" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      post account_connection_path(account)

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Splitwise isn't set up here, so it can't be connected.")
    end

    it "requires sign-in" do
      delete session_path

      post account_connection_path(account)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "DELETE /accounts/:account_id/connection (Disconnect)" do
    it "forgets the token, and keeps the Account, its bank transactions, what they were filed as, the login and the date it reads from" do
      filed = create(:budget_bank_transaction, :filed, account: account)
      ignored = create(:budget_bank_transaction, :ignored, account: account)
      connection.update!(sync_cursor: "2026-10-05T12:00:00Z", synced_at: Time.zone.local(2026, 10, 5, 12))

      expect { delete account_connection_path(account) }
        .not_to change { [ Budget::Account.count, Budget::BankTransaction.count, Budget::Spend.count, Budget::SpendLink.count ] }

      expect(response).to redirect_to(account_path(account))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Disconnected from Splitwise.")
      expect(connection.reload).to have_attributes(access_token: nil, needs_reconnect: false, login_name: "Robert G.", read_from: Date.new(2026, 10, 1), sync_cursor: "2026-10-05T12:00:00Z")
      expect(connection).to be_disconnected
      expect(filed.reload).to be_filed
      expect(ignored.reload).to be_ignored
      expect(account.reload.files_with_rules).to be(false)
    end

    it "forgets a token that needed reconnecting too, and the page says it's disconnected" do
      connection.update!(needs_reconnect: true)

      delete account_connection_path(account)
      follow_redirect!

      expect(visible_text).to include("Disconnected from Splitwise, so this Account isn't syncing.")
      assert_select "[role=status]", text: "Disconnected from Splitwise."
    end

    it "is a 404 for an Account that isn't synced, and another user's Account, and changes nothing" do
      csv = create(:budget_account, budget: budget)
      others = create(:budget_account, :synced)

      delete account_connection_path(csv)
      expect(response).to have_http_status(:not_found)
      delete account_connection_path(others)
      expect(response).to have_http_status(:not_found)
      expect(others.bank_connection.reload).to be_connected
    end

    it "requires sign-in" do
      delete session_path

      delete account_connection_path(account)

      expect(response).to redirect_to(sign_in_path)
      expect(connection.reload).to be_connected
    end
  end
end
