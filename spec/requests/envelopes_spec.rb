require "rails_helper"

RSpec.describe "Envelopes", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }

  before { sign_in_as budget.user }

  describe "GET /months/:month/envelopes/:id" do
    let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 250) }

    it "is headed with the envelope's name, the month as its description, and Edit and Delete as its actions" do
      get month_envelope_path("2026-09", groceries)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Groceries · September 2026 · Budgie"
      assert_select "h1", text: "Groceries"
      assert_select "h1 + p", text: "September 2026"
      assert_select "a.btn[href='#{edit_envelope_path(groceries, month: "2026-09", from: "envelope")}']", text: "Edit"
      assert_select "form[action='#{envelope_path(groceries)}'][data-turbo-confirm='Delete the Groceries envelope?']" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "input[name=month][value='2026-09']"
        assert_select "button", text: "Delete"
      end
    end

    it "shows what it carried over, what's Assigned to it in the month, and what's Available, in that order" do
      get month_envelope_path("2026-09", groceries)

      expect(css_select(".stat-title").map { |title| title.text.strip }).to eq([ "Carried over", "Assigned", "Available" ])
      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "$250.00", "$0.00", "$250.00" ])
      assert_select ".badge", count: 0
    end

    it "shows the month's own Assigned, and what it adds to Available, with what was assigned before it carried over" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 8, 1), amount: 40)
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 1234.5)
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 10, 1), amount: 999)

      get month_envelope_path("2026-09", groceries)

      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "$290.00", "$1,234.50", "$1,524.50" ])
    end

    it "shows what's Assigned, with a way back to the month view to change it, and no input of its own for it" do
      get month_envelope_path("2026-09", groceries)

      assert_select "a[href='#{month_path("2026-09")}']", text: "Back to September 2026"
      assert_select "input[name='assignment[amount]']", count: 0
      assert_select "turbo-frame", count: 0
    end

    it "says Overspent when Available is below zero" do
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)

      get month_envelope_path("2031-12", bills)

      assert_select ".stat-value", text: "-$30.00", count: 1
      assert_select ".stat-value", text: /-\$30\.00\s+Overspent/, count: 1
      assert_select ".badge", text: "Overspent", count: 1
    end

    it "stops saying Overspent once enough is assigned to cover it" do
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      create(:budget_assignment, envelope: bills, month: Date.new(2031, 12, 1), amount: 30)

      get month_envelope_path("2031-12", bills)

      assert_select ".badge", count: 0
      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "-$30.00", "$30.00", "$0.00" ])
    end

    it "has month links that stay on this envelope, and a link back to the month view" do
      travel_to Time.utc(2026, 9, 15, 16)

      get month_envelope_path("2026-09", groceries)

      assert_select "nav[aria-label=Months] a[href='#{month_envelope_path("2026-08", groceries)}']", text: "August 2026"
      assert_select "nav[aria-label=Months] a[href='#{month_envelope_path("2026-10", groceries)}']", text: "October 2026"
      assert_select "a[href='#{month_path("2026-09")}']", text: "Back to September 2026"

      get month_envelope_path("2027-03", groceries)

      assert_select "nav[aria-label=Months] a[href='#{month_envelope_path("2026-09", groceries)}']", text: "This month"
    end

    it "is not found for another user's envelope" do
      get month_envelope_path("2026-09", others_envelope)

      expect(response).to have_http_status(:not_found)
    end

    it "is not found for an envelope that doesn't exist, or a month that isn't one" do
      get month_envelope_path("2026-09", 0)
      expect(response).to have_http_status(:not_found)

      get "/months/2026-09/envelopes/not-an-id"
      expect(response).to have_http_status(:not_found)

      get "/months/2026-13/envelopes/#{groceries.id}"
      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get month_envelope_path("2026-09", groceries)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "the list of envelopes" do
    it "is gone: envelopes are created from the month view, and edited and deleted from their page" do
      get "/envelopes"
      expect(response).to have_http_status(:not_found)

      get "/envelopes/#{create(:budget_envelope, budget: budget).id}"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /envelopes/new" do
    it "shows the form, remembering the page and month it was opened from" do
      get new_envelope_path(month: "2026-09", from: "month")

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "New envelope"
      assert_select "form[action='#{envelopes_path}'] input[name='envelope[name]']"
      assert_select "form input[type=number][name='envelope[starting_balance]'][step='0.01']"
      assert_select "label", text: "Starting balance"
      assert_select "form input[type=hidden][name=from][value=month]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
    end

    it "has a Cancel link back to the month it was opened from" do
      get new_envelope_path(month: "2026-09", from: "month")

      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "is not found for a month that isn't one" do
      get new_envelope_path(month: "2026-13")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /envelopes" do
    it "creates an envelope in the user's budget, and goes back to the month it was opened from" do
      expect { post envelopes_path, params: { envelope: { name: " Groceries ", starting_balance: "-12.34" }, from: "month", month: "2027-03" } }
        .to change(budget.envelopes, :count).by(1)

      expect(budget.envelopes.sole).to have_attributes(name: "Groceries", starting_balance: BigDecimal("-12.34"))
      expect(response).to redirect_to(month_path("2027-03"))
      follow_redirect!
      assert_select "[role=status]", text: "Envelope created."
    end

    it "goes to the current month when it wasn't opened from one" do
      travel_to Time.utc(2026, 9, 15, 16)

      post envelopes_path, params: { envelope: { name: "Groceries" } }

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "saves a blank starting balance as 0" do
      post envelopes_path, params: { envelope: { name: "Groceries", starting_balance: "" } }

      expect(budget.envelopes.sole.starting_balance).to eq(0)
    end

    it "shows errors for an invalid envelope, and remembers where the form was opened from" do
      create(:budget_envelope, budget: budget, name: "Groceries")

      expect { post envelopes_path, params: { envelope: { name: "groceries", starting_balance: "1.234" }, from: "month", month: "2026-09" } }
        .not_to change(Budget::Envelope, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name has already been taken"
      assert_select "[role=alert] li", text: "Starting balance can't have more than 2 decimal places"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "ignores a budget_id in the params" do
      other_budget = create(:budget)

      post envelopes_path, params: { envelope: { name: "Groceries", budget_id: other_budget.id } }

      expect(budget.envelopes.sole.name).to eq("Groceries")
      expect(other_budget.envelopes).to be_empty
    end
  end

  describe "GET /envelopes/:id/edit" do
    let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 50) }

    it "shows the form for the user's envelope" do
      get edit_envelope_path(groceries, month: "2026-09", from: "envelope")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit Groceries · Budgie"
      assert_select "h1", text: "Edit envelope"
      assert_select "form[action='#{envelope_path(groceries)}'] input[name='envelope[name]'][value=Groceries]"
      assert_select "form input[type=hidden][name=from][value=envelope]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
    end

    it "has a Cancel link back to the envelope's page, for the month it was opened from" do
      get edit_envelope_path(groceries, month: "2026-09", from: "envelope")

      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "is not found for another user's envelope" do
      get edit_envelope_path(others_envelope)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /envelopes/:id" do
    let(:envelope) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 50) }

    it "updates the name and starting balance, and goes back to the envelope's page for the month it was opened from" do
      patch envelope_path(envelope), params: { envelope: { name: "Food", starting_balance: "-5" }, from: "envelope", month: "2027-03" }

      expect(envelope.reload).to have_attributes(name: "Food", starting_balance: -5)
      expect(response).to redirect_to(month_envelope_path("2027-03", envelope))
      follow_redirect!
      assert_select "[role=status]", text: "Envelope updated."
      assert_select "h1", text: "Food"
    end

    it "goes back to the month view when it was opened from there, or from something that isn't a page" do
      [ "month", "https://evil.example/", "//evil.example", nil ].each do |from|
        patch envelope_path(envelope), params: { envelope: { name: "Food" }, from: from, month: "2026-09" }

        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "shows errors for an invalid change, and remembers where the form was opened from" do
      patch envelope_path(envelope), params: { envelope: { name: " " }, from: "envelope", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"
      assert_select "a.btn[href='#{month_envelope_path("2026-09", envelope)}']", text: "Cancel"
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
    it "deletes the user's envelope, and goes to the month view for the month it was opened from" do
      envelope = create(:budget_envelope, budget: budget)

      expect { delete envelope_path(envelope), params: { month: "2027-03" } }.to change(Budget::Envelope, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_path("2027-03"))
      follow_redirect!
      assert_select "[role=status]", text: "Envelope deleted."
    end

    it "refuses to delete an envelope with Assigned amounts, says why on the envelope's page, and keeps both" do
      envelope = create(:budget_envelope, budget: budget, name: "Groceries")
      create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }
        .to not_change(Budget::Envelope, :count).and not_change(Budget::Assignment, :count)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_envelope_path("2026-09", envelope))
      follow_redirect!
      assert_select "[role=alert]", text: "This envelope can't be deleted because it has records."
      assert_select "[role=status]", count: 0
      assert_select "h1", text: "Groceries"
    end

    it "stays on the same month's page for the envelope when it refuses" do
      envelope = create(:budget_envelope, budget: budget)
      create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      delete envelope_path(envelope), params: { from: "envelope", month: "2027-03" }

      expect(response).to redirect_to(month_envelope_path("2027-03", envelope))
    end

    it "deletes it once its Assigned amounts are cleared" do
      envelope = create(:budget_envelope, budget: budget)
      assignment = create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      assignment.destroy!

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }.to change(Budget::Envelope, :count).by(-1)
      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "doesn't let the database's own refusal become the way an envelope with records is turned down" do
      envelope = create(:budget_envelope, budget: budget)
      create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      delete envelope_path(envelope), params: { month: "2026-09" }

      expect(response).to have_http_status(:see_other)
      expect(response.body).not_to include("PG::")
    end

    it "goes to the month view even when it was opened from the envelope's own page, which is gone" do
      envelope = create(:budget_envelope, budget: budget)

      delete envelope_path(envelope), params: { from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is not found for another user's envelope, which isn't deleted" do
      others_envelope

      expect { delete envelope_path(others_envelope) }.not_to change(Budget::Envelope, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
