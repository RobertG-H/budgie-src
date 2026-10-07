require "rails_helper"

# Connecting Splitwise (ADR 0016): a form for the Account's name and the date to read from, then Splitwise's OAuth 2 sign-in. What happens when the person comes
# back is in splitwise_callbacks_spec.rb. It isn't signing in to Budgie. Splitwise is replaced by SplitwiseFake (spec/support/splitwise.rb).
RSpec.describe "Connecting Splitwise", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }

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

  describe "GET /splitwise/connection/new" do
    it "is a form for the Account's name, which starts as Splitwise, and the date to read from, with what the date means" do
      get new_splitwise_connection_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Connect Splitwise · Budgie"
      assert_select "h1", text: "Connect Splitwise"
      assert_select "form[action='#{splitwise_connection_path}'][method=post]" do
        assert_select "label[for='account_name']", text: "Account name"
        assert_select "input[type=text][name='account[name]'][value=Splitwise][required]"
        assert_select "label[for='bank_connection_read_from']", text: "Read expenses dated from"
        assert_select "input[type=date][name='bank_connection[read_from]'][required]"
        assert_select "input[type=submit][value='Continue to Splitwise']"
      end
      expect(response.body).to include("Splitwise expenses dated before this are never read.")
      expect(response.body).to include("Starting where your bank transactions start means a shared expense you paid for gets its share back.")
      assert_select "a.btn[href='#{accounts_path}']", text: "Cancel"
    end

    it "sends the form with Turbo off, since it ends in a redirect to another site that a fetch couldn't follow" do
      get new_splitwise_connection_path

      assert_select "form[action='#{splitwise_connection_path}'][data-turbo=false]"
    end

    it "starts the date as the 1st of this month when the budget has no bank transactions" do
      get new_splitwise_connection_path

      assert_select "input[name='bank_connection[read_from]'][value='2026-10-01']"
    end

    it "starts the date as the date of the budget's earliest bank transaction, in any Account and any state" do
      first = create(:budget_account, budget: budget)
      create(:budget_bank_transaction, account: first, date: Date.new(2026, 8, 17))
      create(:budget_bank_transaction, account: create(:budget_account, budget: budget), date: Date.new(2026, 7, 3), amount: 25)
      create(:budget_bank_transaction, account: first, date: Date.new(2026, 9, 1))
      create(:budget_bank_transaction, date: Date.new(2020, 1, 1)) # Someone else's.

      get new_splitwise_connection_path

      assert_select "input[name='bank_connection[read_from]'][value='2026-07-03']"
    end

    it "isn't offered when Splitwise isn't set up here, and says so" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      get new_splitwise_connection_path

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Splitwise isn't set up here, so it can't be connected.")
    end

    it "requires sign-in" do
      delete session_path

      get new_splitwise_connection_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /splitwise/connection" do
    it "sends the person to Splitwise to sign in, with a random state and the callback to come back to, and creates nothing yet" do
      expect { post splitwise_connection_path, params: connect_form }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://secure.splitwise.com/oauth/authorize?")
      expect(splitwise.authorizations).to eq([ { redirect_uri: "http://www.example.com/splitwise/callback", state: state_sent_to_splitwise } ])
      expect(state_sent_to_splitwise).to match(/\A\h{32,}\z/)
    end

    it "uses a new state each time" do
      first = start_connecting
      second = start_connecting

      expect(first).not_to eq(second)
    end

    it "refuses a name that's blank, with the error on the field, and doesn't go to Splitwise" do
      post splitwise_connection_path, params: connect_form(name: "  ")

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"
      assert_select "input[name='account[name]'][aria-invalid=true]"
      expect(splitwise.authorizations).to be_empty
    end

    it "refuses a name the budget's already using, whatever its case, as an Account's name is" do
      create(:budget_account, budget: budget, name: "Splitwise")

      post splitwise_connection_path, params: connect_form(name: "SPLITWISE")

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name has already been taken"
      expect(splitwise.authorizations).to be_empty
    end

    it "may use a name that another budget's Account has" do
      create(:budget_account, name: "Splitwise")

      post splitwise_connection_path, params: connect_form

      expect(response).to have_http_status(:found)
    end

    it "refuses a date that's missing, isn't one, is after tomorrow or is before 1990, and keeps what was typed" do
      { "" => "Read from can't be blank", "not a date" => "Read from can't be blank", "2026-10-08" => "Read from can't be in the future",
        "1989-12-31" => "Read from can't be before 1990" }.each do |date, message|
        post splitwise_connection_path, params: connect_form(name: "My Splitwise", read_from: date)

        expect(response).to have_http_status(:unprocessable_content), date
        assert_select "[role=alert] li", text: message
        assert_select "input[name='account[name]'][value='My Splitwise']"
        assert_select "input[name='bank_connection[read_from]'][aria-invalid=true]"
      end
      expect(splitwise.authorizations).to be_empty
    end

    it "says everything that's wrong at once" do
      create(:budget_account, budget: budget, name: "Splitwise")

      post splitwise_connection_path, params: connect_form(read_from: "2026-10-09")

      assert_select "[role=alert] li", count: 2
    end

    it "isn't done when Splitwise isn't set up here" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      post splitwise_connection_path, params: connect_form

      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Splitwise isn't set up here, so it can't be connected.")
      expect(splitwise.authorizations).to be_empty
    end

    it "requires sign-in" do
      delete session_path

      post splitwise_connection_path, params: connect_form

      expect(response).to redirect_to(sign_in_path)
      expect(splitwise.authorizations).to be_empty
    end
  end
end
