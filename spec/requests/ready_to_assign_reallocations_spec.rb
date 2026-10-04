require "rails_helper"

# Editing and deleting a Reallocation to Ready to Assign. Making one is in reallocations_spec.rb.
RSpec.describe "Reallocations to Ready to Assign", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }
  let!(:fuel) { create(:budget_envelope, budget: budget, name: "Fuel") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }
  let(:others_reallocation) { create(:budget_ready_to_assign_reallocation, envelope: others_envelope, description: "Someone else's") }
  let!(:holiday) do
    create(:budget_ready_to_assign_reallocation, envelope: dining_out, description: "Unspent holiday money",
      date: Date.new(2026, 9, 15), amount: 20, notes: "Back to the pool")
  end

  before { sign_in_as budget.user }

  def choices
    css_select("select[name='reallocation[from_envelope_id]'] option").map { |option| option.text.strip }
  end

  it "is at /reallocations/to-ready-to-assign/:id, which spells nothing with underscores" do
    expect(edit_ready_to_assign_reallocation_path(holiday)).to eq("/reallocations/to-ready-to-assign/#{holiday.id}/edit")
    expect(ready_to_assign_reallocation_path(holiday)).to eq("/reallocations/to-ready-to-assign/#{holiday.id}")
  end

  describe "GET /reallocations/to-ready-to-assign/:id/edit" do
    it "shows the form for the user's Reallocation, filled in, with From chosen and To shown as text" do
      get edit_ready_to_assign_reallocation_path(holiday, month: "2026-09", from: "envelope", envelope: dining_out.id)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit reallocation · Budgie"
      assert_select "h1", text: "Edit reallocation"
      assert_select "form[action='#{ready_to_assign_reallocation_path(holiday)}'][method=post]" do
        assert_select "input[name='_method'][value=patch]"
        assert_select "select[name='reallocation[from_envelope_id]'] option[selected][value='#{dining_out.id}']", text: "Dining out"
        assert_select "select[name='reallocation[to_envelope_id]']", count: 0
        assert_select "p", text: "Ready to Assign"
        assert_select "input[name='reallocation[description]'][value='Unspent holiday money'][autofocus]"
        assert_select "input[name='reallocation[date]'][value='2026-09-15']"
        assert_select "textarea[name='reallocation[notes]']", text: "Back to the pool"
        assert_select "input[type=submit][value='Update Reallocation']"
      end
      expect(BigDecimal(css_select("input[name='reallocation[amount]']").first["value"])).to eq(20)
    end

    it "lets From be changed to any of the budget's envelopes, and offers no one else's" do
      others_envelope

      get edit_ready_to_assign_reallocation_path(holiday, month: "2026-09")

      expect(choices).to eq([ "Dining out", "Fuel", "Groceries" ])
    end

    it "offers to delete the Reallocation, behind a confirmation, and remembers where the form was opened from" do
      get edit_ready_to_assign_reallocation_path(holiday, month: "2026-09", from: "deposits")

      assert_select "form[action='#{ready_to_assign_reallocation_path(holiday)}'][data-turbo-confirm='Delete the Unspent holiday money reallocation?']" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "input[name=from][value=deposits]"
        assert_select "input[name=month][value='2026-09']"
        assert_select "button", text: "Delete"
      end
    end

    it "has a Cancel link back to the page it was opened from: its envelope's page, a month's Deposits, or the month view" do
      get edit_ready_to_assign_reallocation_path(holiday, month: "2026-09", from: "envelope", envelope: dining_out.id)
      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"

      get edit_ready_to_assign_reallocation_path(holiday, month: "2026-09", from: "deposits")
      assert_select "a.btn[href='#{month_deposits_path("2026-09")}']", text: "Cancel"

      get edit_ready_to_assign_reallocation_path(holiday, month: "2026-09", from: "month")
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "has a Cancel link to its envelope's page when it was opened from the page of another envelope" do
      get edit_ready_to_assign_reallocation_path(holiday, month: "2026-09", from: "envelope", envelope: fuel.id)

      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"
    end

    it "is not found for another user's Reallocation" do
      get edit_ready_to_assign_reallocation_path(others_reallocation)

      expect(response).to have_http_status(:not_found)
    end

    it "is not found at the address of a Reallocation to an envelope: ids repeat across the two tables" do
      get "/reallocations/to-envelope/#{holiday.id}/edit"

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get edit_ready_to_assign_reallocation_path(holiday)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "PATCH /reallocations/to-ready-to-assign/:id" do
    it "updates the Reallocation, and goes back to the envelope page it was opened from" do
      patch ready_to_assign_reallocation_path(holiday),
        params: { reallocation: { description: "Holiday, again", amount: "250.5", notes: "Bulk" }, from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(holiday.reload).to have_attributes(description: "Holiday, again", amount: BigDecimal("250.5"), notes: "Bulk", envelope: dining_out)
      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
      follow_redirect!
      assert_select "[role=status]", text: "Reallocation updated."
    end

    it "goes back to a month's Deposits page when it was opened from there, for the month of its date" do
      patch ready_to_assign_reallocation_path(holiday), params: { reallocation: { date: "2026-10-03" }, from: "deposits", month: "2026-09" }

      expect(holiday.reload.date).to eq(Date.new(2026, 10, 3))
      expect(response).to redirect_to(month_deposits_path("2026-10"))
    end

    it "changes From to another of the budget's envelopes, and goes to the new From's page when the page it was opened from is out of it now" do
      patch ready_to_assign_reallocation_path(holiday),
        params: { reallocation: { from_envelope_id: fuel.id }, from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(holiday.reload.envelope).to eq(fuel)
      expect(response).to redirect_to(month_envelope_path("2026-09", fuel))
    end

    it "leaves where it goes alone when an update sends a different To" do
      patch ready_to_assign_reallocation_path(holiday),
        params: { reallocation: { to_envelope_id: groceries.id, description: "Holiday, again" }, from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(holiday.reload).to have_attributes(envelope: dining_out, description: "Holiday, again")
      expect(Budget::ReadyToAssignReallocation.count).to eq(1)
      expect(Budget::EnvelopeReallocation.count).to eq(0)
      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
    end

    it "goes to the month view for the month of its date when it was opened from there, and when told to go anywhere else" do
      patch ready_to_assign_reallocation_path(holiday), params: { reallocation: { date: "2026-11-03" }, from: "month", month: "2026-09" }
      expect(response).to redirect_to(month_path("2026-11"))

      patch ready_to_assign_reallocation_path(holiday), params: { reallocation: { description: "Again" }, from: "https://evil.example/", month: "2026-09" }
      expect(response).to redirect_to(month_path("2026-11"))
    end

    it "keeps From when none is given" do
      patch ready_to_assign_reallocation_path(holiday), params: { reallocation: { description: "Holiday, again" } }

      expect(holiday.reload).to have_attributes(description: "Holiday, again", envelope: dining_out)
    end

    it "shows what's wrong, and keeps the form, for an invalid change" do
      patch ready_to_assign_reallocation_path(holiday),
        params: { reallocation: { description: "", amount: "-5" }, from: "deposits", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "form input[name=from][value=deposits]"
      assert_select "h1", text: "Edit reallocation"
      assert_select "p", text: "Ready to Assign"
      assert_select "a.btn[href='#{month_deposits_path("2026-09")}']", text: "Cancel"
      expect(holiday.reload).to have_attributes(description: "Unspent holiday money", amount: 20)
    end

    it "refuses another budget's envelope as From, as an error on the From field, and leaves the Reallocation where it was" do
      patch ready_to_assign_reallocation_path(holiday), params: { reallocation: { from_envelope_id: others_envelope.id }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "From can't be blank"
      assert_select "select[name='reallocation[from_envelope_id]'][aria-invalid=true]"
      expect(holiday.reload.envelope).to eq(dining_out)
      expect(response.body).not_to include("Someone else")
    end

    it "refuses a blank From, and leaves the Reallocation where it was" do
      patch ready_to_assign_reallocation_path(holiday), params: { reallocation: { from_envelope_id: "" }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "From can't be blank"
      expect(holiday.reload.envelope).to eq(dining_out)
    end

    it "has Cancel go back to the page of the envelope the Reallocation is still in when a change of From is refused" do
      patch ready_to_assign_reallocation_path(holiday),
        params: { reallocation: { from_envelope_id: fuel.id, amount: "0" }, from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "select[name='reallocation[from_envelope_id]'] option[selected][value='#{fuel.id}']"
      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"
    end

    it "is not found for another user's Reallocation, which stays unchanged" do
      patch ready_to_assign_reallocation_path(others_reallocation), params: { reallocation: { description: "Mine now", from_envelope_id: groceries.id } }

      expect(response).to have_http_status(:not_found)
      expect(others_reallocation.reload).to have_attributes(description: "Someone else's", envelope: others_envelope)
    end
  end

  describe "DELETE /reallocations/to-ready-to-assign/:id" do
    it "deletes the Reallocation, and goes back to the month view for the month of its date" do
      expect { delete ready_to_assign_reallocation_path(holiday), params: { from: "month", month: "2026-10" } }
        .to change(Budget::ReadyToAssignReallocation, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Reallocation deleted."
    end

    it "goes back to a month's Deposits page for the month of its date when it was opened from there" do
      delete ready_to_assign_reallocation_path(holiday), params: { from: "deposits", month: "2026-10" }

      expect(response).to redirect_to(month_deposits_path("2026-09"))
    end

    it "goes back to the page of the envelope it was opened from, or its own envelope's when that is not it" do
      other = create(:budget_ready_to_assign_reallocation, envelope: dining_out, date: Date.new(2026, 9, 15))

      delete ready_to_assign_reallocation_path(holiday), params: { from: "envelope", month: "2026-09", envelope: dining_out.id }
      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))

      delete ready_to_assign_reallocation_path(other), params: { from: "envelope", month: "2026-09", envelope: fuel.id }
      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
    end

    it "goes to the month view when it isn't told where to go back to" do
      delete ready_to_assign_reallocation_path(holiday)

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is not found for another user's Reallocation, which isn't deleted" do
      others_reallocation

      expect { delete ready_to_assign_reallocation_path(others_reallocation) }.not_to change(Budget::ReadyToAssignReallocation, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
