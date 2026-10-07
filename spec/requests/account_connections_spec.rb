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

  describe "syncing, on the Account's page" do
    it "offers Sync now, which says nothing yet about when it last synced", :aggregate_failures do
      get account_path(account)

      assert_select "form[action='#{account_connection_sync_path(account)}'][method=post]" do
        assert_select "button", text: "Sync now"
      end
      expect(visible_text).to include("Not synced yet.")
    end

    it "says when it last synced, in words" do
      connection.update_columns(synced_at: 12.minutes.ago)

      get account_path(account)

      expect(visible_text).to include("Last synced 12 minutes ago.")
      expect(visible_text).not_to include("Not synced yet")
    end

    it "offers no Sync now while it needs reconnecting or is disconnected, though it still says when it last synced" do
      connection.update_columns(synced_at: 2.days.ago, needs_reconnect: true)
      get account_path(account)
      assert_select "button", text: "Sync now", count: 0
      expect(visible_text).to include("Last synced 2 days ago.")

      connection.disconnect!
      get account_path(account)
      assert_select "button", text: "Sync now", count: 0
    end

    it "offers no Sync now where Splitwise isn't set up, since a token can't be read there" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      get account_path(account)

      assert_select "button", text: "Sync now", count: 0
    end

    it "has the date to read from, which can be changed, with what it does in words" do
      get account_path(account)

      assert_select "form[action='#{account_connection_path(account)}'] input[name=_method][value=patch]"
      assert_select "input[type=date][name='bank_connection[read_from]'][value='2026-10-01'][required]"
      assert_select "form input[type=submit][value='Change date']"
      expect(visible_text).to include("Splitwise expenses dated before this are never read.")
      expect(visible_text).to include("Changing it makes the next sync read every expense dated from it again. What's already here stays as it is.")
    end

    it "shows what a bank transaction brought in says about it: filed, ignored and deleted in Splitwise, each in words", :aggregate_failures do
      create(:budget_bank_transaction, :ignored, account: account, description: "Jane paid me back", amount: 50)
      create(:budget_bank_transaction, :removed, account: account, description: "Deleted dinner", amount: -30)
      filed = create(:budget_bank_transaction, :filed, :removed, account: account, description: "Deleted lunch", amount: -20)

      get account_path(account)

      expect(visible_text).to include("Jane paid me back", "Deleted dinner", "Deleted lunch")
      assert_select "li", text: /Deleted dinner/ do
        assert_select ".badge", text: "Deleted in Splitwise"
        assert_select "a[href*='filing']", count: 0
      end
      assert_select "li", text: /Deleted lunch/ do
        assert_select ".badge", text: "Deleted in Splitwise"
        assert_select "button", text: "Un-file"
      end
      expect(filed.reload).to be_filed
    end
  end

  describe "POST /accounts/:account_id/connection/sync (Sync now)" do
    before do
      splitwise.signs_in("code", as: Splitwise::Person.new(id: "7654321", name: "Robert G."), token: "its-token")
      splitwise.expense(1, "Dinner", net_balance: "50.00", date: "2026-10-03")
      splitwise.expense(2, "Groceries", net_balance: "-40.00", date: "2026-10-05")
      splitwise.expense(3, "Jane paid me back", net_balance: "50.00", date: "2026-10-06", payment: true)
      splitwise.expense(4, "Between others", net_balance: nil, date: "2026-10-06")
    end

    it "syncs the Account and says what it did, going back to the Account's page" do
      post account_connection_sync_path(account)

      expect(response).to redirect_to(account_path(account))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Synced from Splitwise: 2 new. 1 settle-up ignored, 1 skipped.")
      expect(account.bank_transactions.pluck(:description)).to contain_exactly("Dinner", "Groceries", "Jane paid me back")
      expect(connection.reload.synced_at).to be_present
    end

    it "links its notice to the Account's To review state whenever Filing rules filed or ignored anything, which is where it is to review" do
      account.update!(files_with_rules: true)
      create(:budget_filing_rule, budget: budget, text: "groceries")

      post account_connection_sync_path(account)
      follow_redirect!

      assert_select "[role=status]", text: /Filing rules filed 1 of them\. Review them/
      assert_select "[role=status] a[href='#{bank_transactions_path(filter: { state: "to_review", account: account.id })}']", text: "Review them"
      expect(Budget::BankTransaction.to_review.pluck(:description)).to eq([ "Groceries" ])
    end

    it "has no link in its notice when Filing rules did nothing" do
      post account_connection_sync_path(account)
      follow_redirect!

      assert_select "[role=status] a", count: 0
      expect(flash[:review_path]).to be_nil
    end

    it "shows when it synced on the page it goes back to" do
      post account_connection_sync_path(account)
      follow_redirect!

      expect(visible_text).to include("Synced from Splitwise: 2 new.")
      expect(visible_text).to include("Last synced less than a minute ago.")
    end

    it "says there's nothing new when there isn't, and syncing again brings nothing in twice" do
      2.times { post account_connection_sync_path(account) }

      # What Splitwise changed a moment ago is read again, which is why the one that was skipped is counted again.
      expect(flash[:notice]).to start_with("Synced from Splitwise: nothing new.")
      expect(account.bank_transactions.count).to eq(3)
    end

    it "asks to reconnect when Splitwise no longer accepts the sign-in, which the page then says" do
      splitwise.revoke("its-token")

      post account_connection_sync_path(account)

      expect(response).to redirect_to(account_path(account))
      expect(flash[:alert]).to eq("Splitwise stopped accepting the sign-in as Robert G., so nothing was synced. Reconnect to start again.")
      expect(connection.reload).to be_needs_reconnect
      follow_redirect!
      expect(visible_text).to include("Splitwise stopped accepting the sign-in as Robert G., so this Account isn't syncing. Reconnect to start again.")
    end

    it "says to try again later when Splitwise is limiting how often it can be asked, and keeps the sign-in and the marker" do
      splitwise.fails_at_offset(0, Splitwise::RateLimited.new("Splitwise is limiting how often Budgie can ask."))

      post account_connection_sync_path(account)

      expect(flash[:alert]).to eq("Splitwise is limiting how often Budgie can ask, so nothing was synced. Try again later.")
      expect(connection.reload).to have_attributes(needs_reconnect: false, sync_cursor: nil)
      expect(account.bank_transactions).to be_empty
    end

    it "says why when Splitwise couldn't be reached, and nothing was brought in" do
      splitwise.fails_with(Splitwise::Error.new("Splitwise couldn't be reached."))

      post account_connection_sync_path(account)

      expect(flash[:alert]).to eq("Splitwise couldn't be reached, so nothing was synced. Try again later.")
      expect(account.bank_transactions).to be_empty
    end

    it "says nothing was synced when something goes wrong that isn't Splitwise's, and logs it with the connection's id" do
      allow(SyncSplitwise).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "the database said no")
      logged = StringIO.new
      logger = ActiveSupport::Logger.new(logged)
      Rails.logger.broadcast_to(logger)

      post account_connection_sync_path(account)

      expect(response).to redirect_to(account_path(account))
      expect(flash[:alert]).to eq("Something went wrong, so nothing was synced. Try again later.")
      expect(logged.string).to include("connection #{connection.id}", "the database said no")
    ensure
      Rails.logger.stop_broadcasting_to(logger)
    end

    it "is turned away for a connection that's disconnected or needs reconnecting, without asking Splitwise" do
      connection.update_columns(needs_reconnect: true)
      post account_connection_sync_path(account)
      expect(flash[:alert]).to eq("Splitwise stopped accepting the sign-in as Robert G., so it isn't syncing. Reconnect to start again.")

      connection.reconnect!(access_token: "its-token", login_name: "Robert G.")
      connection.disconnect!
      post account_connection_sync_path(account)
      expect(flash[:alert]).to eq("This Account is disconnected from Splitwise, so it isn't syncing. Reconnect to start again.")

      expect(splitwise.expense_requests).to be_empty
    end

    it "isn't done where Splitwise isn't set up" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      post account_connection_sync_path(account)

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Splitwise isn't set up here, so it can't be synced.")
    end

    it "is a 404 for an Account that isn't synced, and another user's, and asks Splitwise nothing" do
      csv = create(:budget_account, budget: budget)
      others = create(:budget_account, :synced)
      splitwise.signs_in("other", as: Splitwise::Person.new(id: others.bank_connection.login_id, name: "Someone"), token: "splitwise-access-token")

      post account_connection_sync_path(csv)
      expect(response).to have_http_status(:not_found)
      post account_connection_sync_path(others)
      expect(response).to have_http_status(:not_found)

      expect(splitwise.expense_requests).to be_empty
      expect(others.bank_transactions).to be_empty
    end

    it "requires sign-in" do
      delete session_path

      post account_connection_sync_path(account)

      expect(response).to redirect_to(sign_in_path)
      expect(splitwise.expense_requests).to be_empty
    end

    it "never puts the token in what it says" do
      splitwise.revoke("its-token")

      post account_connection_sync_path(account)
      follow_redirect!

      expect(response.body).not_to include("its-token")
    end
  end

  describe "PATCH /accounts/:account_id/connection (the date to read from)" do
    before { connection.update_columns(sync_cursor: "2026-10-05T12:00:00Z", synced_at: Time.zone.local(2026, 10, 5, 12)) }

    it "changes the date and forgets the marker, so the next sync reads every expense dated from it again, and says so" do
      patch account_connection_path(account), params: { bank_connection: { read_from: "2026-09-01" } }

      expect(response).to redirect_to(account_path(account))
      expect(flash[:notice]).to eq("Now reading expenses dated from Sep 1, 2026. The next sync reads them again.")
      expect(connection.reload).to have_attributes(read_from: Date.new(2026, 9, 1), sync_cursor: nil)
      expect(connection.synced_at).to be_present
    end

    it "leaves what's already in the Account as it is, when it moves later, and the Account's bank transactions untouched" do
      filed = create(:budget_bank_transaction, :filed, account: account, date: Date.new(2026, 10, 2))

      patch account_connection_path(account), params: { bank_connection: { read_from: Date.new(2026, 10, 6).iso8601 } }

      expect(connection.reload.read_from).to eq(Date.new(2026, 10, 6))
      expect(account.bank_transactions).to eq([ filed ])
      expect(filed.reload).to be_filed
    end

    it "refuses a date that isn't one, a date in the future and one before 1990, and changes nothing" do
      { "" => "Read from can't be blank", "not a date" => "Read from can't be blank", "2099-01-01" => "Read from can't be in the future",
        "1989-12-31" => "Read from can't be before 1990" }.each do |date, message|
        patch account_connection_path(account), params: { bank_connection: { read_from: date } }

        expect(response).to redirect_to(account_path(account))
        expect(flash[:alert]).to eq("#{message}.")
        expect(connection.reload).to have_attributes(read_from: Date.new(2026, 10, 1), sync_cursor: "2026-10-05T12:00:00Z")
      end
    end

    it "changes nothing else, whatever else is sent: the login, the token and the budget are never params" do
      other = create(:budget)

      patch account_connection_path(account), params: { bank_connection: { read_from: "2026-09-01", login_id: "1", login_name: "Eve", access_token: "stolen", budget_id: other.id, needs_reconnect: "1" } }

      expect(connection.reload).to have_attributes(login_id: "7654321", login_name: "Robert G.", access_token: "its-token", budget_id: budget.id, needs_reconnect: false)
    end

    it "can be done for a connection that's disconnected, since it's only what a later sync reads from" do
      connection.disconnect!

      patch account_connection_path(account), params: { bank_connection: { read_from: "2026-09-01" } }

      expect(connection.reload.read_from).to eq(Date.new(2026, 9, 1))
    end

    it "is a 404 for an Account that isn't synced, and another user's, and changes nothing" do
      csv = create(:budget_account, budget: budget)
      others = create(:budget_account, :synced)

      patch account_connection_path(csv), params: { bank_connection: { read_from: "2026-09-01" } }
      expect(response).to have_http_status(:not_found)
      patch account_connection_path(others), params: { bank_connection: { read_from: "2026-09-01" } }
      expect(response).to have_http_status(:not_found)
      expect(others.bank_connection.reload.read_from).to eq(Date.new(2026, 10, 1))
    end

    it "requires sign-in" do
      delete session_path

      patch account_connection_path(account), params: { bank_connection: { read_from: "2026-09-01" } }

      expect(response).to redirect_to(sign_in_path)
      expect(connection.reload.read_from).to eq(Date.new(2026, 10, 1))
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
