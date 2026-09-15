require "rails_helper"

RSpec.describe "Envelopes", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }

  before { sign_in_as budget.user }

  describe "GET /envelopes" do
    it "is the root page" do
      get root_path

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "Envelopes"
    end

    it "lists the budget's envelopes alphabetically with their starting balances" do
      create(:budget_envelope, budget: budget, name: "rent", starting_balance: 1234.5)
      create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      others_envelope

      get envelopes_path

      assert_select "tbody tr", count: 2
      assert_select "tbody tr:nth-child(1) td", text: "Bills"
      assert_select "tbody tr:nth-child(1) td", text: "-$30.00"
      assert_select "tbody tr:nth-child(2) td", text: "rent"
      assert_select "tbody tr:nth-child(2) td", text: "$1,234.50"
      assert_select "tbody tr:nth-child(2) a[href='#{edit_envelope_path(budget.envelopes.find_by!(name: "rent"))}']", text: "Edit"
      assert_select "tbody tr:nth-child(2) form[data-turbo-confirm] button", text: "Delete"
      expect(response.body).not_to include("Someone else&#39;s")
    end

    it "shows the budget's currency once, in the header, with an Envelopes link" do
      create(:budget_envelope, budget: budget)

      get envelopes_path

      assert_select "header", text: /Budget in CAD/
      assert_select "nav a[href='#{envelopes_path}']", text: "Envelopes"
      expect(response.body.scan("CAD").size).to eq(1)
    end

    it "says when there are no envelopes" do
      get envelopes_path

      assert_select "main", text: /You don't have any envelopes yet./
    end
  end

  describe "GET /envelopes/new" do
    it "shows the form" do
      get new_envelope_path

      expect(response).to have_http_status(:ok)
      assert_select "form[action='#{envelopes_path}'] input[name='envelope[name]']"
      assert_select "form input[type=number][name='envelope[starting_balance]'][step='0.01']"
      assert_select "label", text: "Starting balance"
    end
  end

  describe "POST /envelopes" do
    it "creates an envelope in the user's budget" do
      expect { post envelopes_path, params: { envelope: { name: " Groceries ", starting_balance: "-12.34" } } }
        .to change(budget.envelopes, :count).by(1)

      expect(budget.envelopes.sole).to have_attributes(name: "Groceries", starting_balance: BigDecimal("-12.34"))
      expect(response).to redirect_to(envelopes_path)
      follow_redirect!
      assert_select "[role=status]", text: "Envelope created."
    end

    it "saves a blank starting balance as 0" do
      post envelopes_path, params: { envelope: { name: "Groceries", starting_balance: "" } }

      expect(budget.envelopes.sole.starting_balance).to eq(0)
    end

    it "shows errors for an invalid envelope" do
      create(:budget_envelope, budget: budget, name: "Groceries")

      expect { post envelopes_path, params: { envelope: { name: "groceries", starting_balance: "1.234" } } }
        .not_to change(Budget::Envelope, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name has already been taken"
      assert_select "[role=alert] li", text: "Starting balance can't have more than 2 decimal places"
    end

    it "ignores a budget_id in the params" do
      other_budget = create(:budget)

      post envelopes_path, params: { envelope: { name: "Groceries", budget_id: other_budget.id } }

      expect(budget.envelopes.sole.name).to eq("Groceries")
      expect(other_budget.envelopes).to be_empty
    end
  end

  describe "GET /envelopes/:id/edit" do
    it "shows the form for the user's envelope" do
      envelope = create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 50)

      get edit_envelope_path(envelope)

      expect(response).to have_http_status(:ok)
      assert_select "form[action='#{envelope_path(envelope)}'] input[name='envelope[name]'][value=Groceries]"
    end

    it "is not found for another user's envelope" do
      get edit_envelope_path(others_envelope)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /envelopes/:id" do
    let(:envelope) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 50) }

    it "updates the name and starting balance" do
      patch envelope_path(envelope), params: { envelope: { name: "Food", starting_balance: "-5" } }

      expect(envelope.reload).to have_attributes(name: "Food", starting_balance: -5)
      expect(response).to redirect_to(envelopes_path)
      follow_redirect!
      assert_select "[role=status]", text: "Envelope updated."
    end

    it "shows errors for an invalid change" do
      patch envelope_path(envelope), params: { envelope: { name: " " } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"
      expect(envelope.reload.name).to eq("Groceries")
    end

    it "doesn't move the envelope to another budget" do
      other_budget = create(:budget)

      patch envelope_path(envelope), params: { envelope: { name: "Food", budget_id: other_budget.id } }

      expect(envelope.reload.budget).to eq(budget)
    end

    it "is not found for another user's envelope, which stays unchanged" do
      patch envelope_path(others_envelope), params: { envelope: { name: "Mine now" } }

      expect(response).to have_http_status(:not_found)
      expect(others_envelope.reload.name).to eq("Someone else's")
    end
  end

  describe "DELETE /envelopes/:id" do
    it "deletes the user's envelope" do
      envelope = create(:budget_envelope, budget: budget)

      expect { delete envelope_path(envelope) }.to change(Budget::Envelope, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(envelopes_path)
      follow_redirect!
      assert_select "[role=status]", text: "Envelope deleted."
    end

    it "is not found for another user's envelope, which isn't deleted" do
      others_envelope

      expect { delete envelope_path(others_envelope) }.not_to change(Budget::Envelope, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
