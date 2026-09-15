require "rails_helper"

RSpec.describe "Budget setup", type: :request do
  let(:user) { create(:user) }

  describe "the setup gate" do
    before { sign_in_as user }

    it "sends a user without a budget to setup from any page" do
      get root_path
      expect(response).to redirect_to(new_budget_path)

      get new_envelope_path
      expect(response).to redirect_to(new_budget_path)

      post envelopes_path, params: { envelope: { name: "Groceries" } }
      expect(response).to redirect_to(new_budget_path)
    end

    it "still lets a user without a budget sign out" do
      delete session_path

      expect(response).to redirect_to(sign_in_path)
    end

    it "lets a user with a budget through" do
      create(:budget, user: user)

      get root_path

      expect(response).to have_http_status(:ok)
    end
  end

  it "sends a newly signed-in user to setup, then to the envelope list" do
    create(:invite, email: "robin@example.com")

    sign_in_with_google(email: "robin@example.com")
    follow_redirect!
    expect(response).to redirect_to(new_budget_path)

    post budget_path, params: { budget: { currency: "USD" } }
    expect(response).to redirect_to(envelopes_path)

    follow_redirect!
    expect(response).to have_http_status(:ok)
    assert_select "[role=status]", text: "Your budget is ready."
    assert_select "header", text: /Budget in USD/
  end

  describe "GET /budget/new" do
    before { sign_in_as user }

    it "asks for a currency with nothing chosen" do
      get new_budget_path

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "Set up your budget"
      assert_select "p", text: "Choose the currency for your budget. All amounts are in this currency."
      assert_select "select[name='budget[currency]'] option[value='']", text: "Choose a currency"
      assert_select "select[name='budget[currency]'] option[selected]", count: 0
      assert_select "select[name='budget[currency]'] option[value=CAD]", text: "Canadian dollar (CAD)"
      assert_select "input[type=submit][value='Create budget']"
    end

    it "sends a user who already has a budget to the envelope list" do
      create(:budget, user: user)

      get new_budget_path

      expect(response).to redirect_to(envelopes_path)
    end

    it "requires sign-in" do
      delete session_path

      get new_budget_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /budget" do
    before { sign_in_as user }

    it "creates the budget in the chosen currency" do
      expect { post budget_path, params: { budget: { currency: "EUR" } } }.to change(Budget, :count).by(1)

      expect(user.reload.budget.currency).to eq("EUR")
      expect(response).to redirect_to(envelopes_path)
    end

    it "shows an error when no currency is chosen" do
      expect { post budget_path, params: { budget: { currency: "" } } }.not_to change(Budget, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Currency can't be blank/
      assert_select "select[name='budget[currency]'] option[value='']", text: "Choose a currency"
    end

    it "rejects a currency that isn't supported" do
      expect { post budget_path, params: { budget: { currency: "JPY" } } }.not_to change(Budget, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "sends a user who already has a budget to the envelope list without changing it" do
      budget = create(:budget, user: user, currency: "CAD")

      expect { post budget_path, params: { budget: { currency: "USD" } } }.not_to change(Budget, :count)

      expect(response).to redirect_to(envelopes_path)
      expect(budget.reload.currency).to eq("CAD")
    end

    it "sends a double submit to the envelope list when the database refuses a second budget" do
      create(:budget, user: user)
      # Both submissions got past the check for an existing budget before either was saved.
      allow_any_instance_of(User).to receive(:budget).and_return(nil)

      expect { post budget_path, params: { budget: { currency: "USD" } } }.not_to change(Budget, :count)

      expect(response).to redirect_to(envelopes_path)
    end
  end
end
