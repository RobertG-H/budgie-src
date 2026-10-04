require "rails_helper"

# Editing and deleting a Reallocation to an envelope. Making one is in reallocations_spec.rb.
RSpec.describe "Reallocations to an envelope", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }
  let!(:fuel) { create(:budget_envelope, budget: budget, name: "Fuel") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }
  let(:others_reallocation) { create(:budget_envelope_reallocation, from_envelope: others_envelope, description: "Someone else's") }
  let!(:dentist) do
    create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries, description: "Covering the dentist",
      date: Date.new(2026, 9, 15), amount: 20, notes: "Just this once")
  end

  before { sign_in_as budget.user }

  def choices
    css_select("select[name='reallocation[from_envelope_id]'] option").map { |option| option.text.strip }
  end

  it "is at /reallocations/to-envelope/:id" do
    expect(edit_envelope_reallocation_path(dentist)).to eq("/reallocations/to-envelope/#{dentist.id}/edit")
    expect(envelope_reallocation_path(dentist)).to eq("/reallocations/to-envelope/#{dentist.id}")
  end

  describe "GET /reallocations/to-envelope/:id/edit" do
    it "shows the form for the user's Reallocation, filled in, with From chosen and To shown as text" do
      get edit_envelope_reallocation_path(dentist, month: "2026-09", from: "envelope", envelope: groceries.id)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit reallocation · Budgie"
      assert_select "h1", text: "Edit reallocation"
      assert_select "form[action='#{envelope_reallocation_path(dentist)}'][method=post]" do
        assert_select "input[name='_method'][value=patch]"
        assert_select "select[name='reallocation[from_envelope_id]'] option[selected][value='#{dining_out.id}']", text: "Dining out"
        assert_select "select[name='reallocation[to_envelope_id]']", count: 0
        assert_select "p", text: "Groceries"
        assert_select "input[name='reallocation[description]'][value='Covering the dentist'][autofocus]"
        assert_select "input[name='reallocation[date]'][value='2026-09-15']"
        assert_select "textarea[name='reallocation[notes]']", text: "Just this once"
        assert_select "input[type=submit][value='Update Reallocation']"
      end
      expect(BigDecimal(css_select("input[name='reallocation[amount]']").first["value"])).to eq(20)
    end

    it "lets From be changed to any of the budget's envelopes, and offers no one else's" do
      others_envelope

      get edit_envelope_reallocation_path(dentist, month: "2026-09")

      expect(choices).to eq([ "Dining out", "Fuel", "Groceries" ])
    end

    it "offers to delete the Reallocation, behind a confirmation, and remembers where the form was opened from" do
      get edit_envelope_reallocation_path(dentist, month: "2026-09", from: "envelope", envelope: groceries.id)

      assert_select "form[action='#{envelope_reallocation_path(dentist)}'][data-turbo-confirm='Delete the Covering the dentist reallocation?']" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "input[name=from][value=envelope]"
        assert_select "input[name=month][value='2026-09']"
        assert_select "input[name=envelope][value='#{groceries.id}']"
        assert_select "button", text: "Delete"
      end
    end

    it "carries the envelope whose page it was opened from, so saving can go back to it" do
      get edit_envelope_reallocation_path(dentist, month: "2026-09", from: "envelope", envelope: groceries.id)

      assert_select "form[action='#{envelope_reallocation_path(dentist)}'] input[type=hidden][name=envelope][value='#{groceries.id}']"
    end

    it "has a Cancel link back to the page it was opened from: either of its envelopes' pages, or the month view" do
      get edit_envelope_reallocation_path(dentist, month: "2026-09", from: "envelope", envelope: groceries.id)
      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"

      get edit_envelope_reallocation_path(dentist, month: "2026-09", from: "envelope", envelope: dining_out.id)
      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"

      get edit_envelope_reallocation_path(dentist, month: "2026-09", from: "month")
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "has a Cancel link to the From envelope's page when it was opened from the page of an envelope it isn't in or out of" do
      get edit_envelope_reallocation_path(dentist, month: "2026-09", from: "envelope", envelope: fuel.id)

      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"
    end

    it "is not found for another user's Reallocation" do
      get edit_envelope_reallocation_path(others_reallocation)

      expect(response).to have_http_status(:not_found)
    end

    it "is not found for a Reallocation to Ready to Assign's address: ids repeat across the two tables" do
      get "/reallocations/to-ready-to-assign/#{dentist.id}/edit"

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get edit_envelope_reallocation_path(dentist)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "PATCH /reallocations/to-envelope/:id" do
    it "updates the Reallocation, and goes back to the envelope page it was opened from" do
      patch envelope_reallocation_path(dentist),
        params: { reallocation: { description: "Dentist, again", amount: "250.5", notes: "Bulk" }, from: "envelope", month: "2026-09", envelope: groceries.id }

      expect(dentist.reload).to have_attributes(
        description: "Dentist, again", amount: BigDecimal("250.5"), notes: "Bulk", from_envelope: dining_out, to_envelope: groceries
      )
      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
      follow_redirect!
      assert_select "[role=status]", text: "Reallocation updated."
    end

    it "goes back to the From envelope's page when it was opened from there" do
      patch envelope_reallocation_path(dentist), params: { reallocation: { amount: "5" }, from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
    end

    it "changes From to another of the budget's envelopes, and goes to the new From's page when the page it was opened from is out of it now" do
      patch envelope_reallocation_path(dentist),
        params: { reallocation: { from_envelope_id: fuel.id }, from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(dentist.reload).to have_attributes(from_envelope: fuel, to_envelope: groceries)
      expect(response).to redirect_to(month_envelope_path("2026-09", fuel))
    end

    it "stays on the To envelope's page when From is changed and the page it was opened from is still in it" do
      patch envelope_reallocation_path(dentist),
        params: { reallocation: { from_envelope_id: fuel.id }, from: "envelope", month: "2026-09", envelope: groceries.id }

      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
    end

    it "leaves To where it went when an update sends a different one" do
      patch envelope_reallocation_path(dentist),
        params: { reallocation: { to_envelope_id: fuel.id, description: "Dentist, again" }, from: "envelope", month: "2026-09", envelope: groceries.id }

      expect(dentist.reload).to have_attributes(to_envelope: groceries, from_envelope: dining_out, description: "Dentist, again")
      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
    end

    it "leaves To where it went when an update sends another budget's envelope, or nothing" do
      [ others_envelope.id, "", 0 ].each do |to|
        patch envelope_reallocation_path(dentist), params: { reallocation: { to_envelope_id: to, amount: "21" } }

        expect(response).to redirect_to(month_path("2026-09"))
        expect(dentist.reload.to_envelope).to eq(groceries)
      end
    end

    it "follows a changed date to the month it's dated in now, not the one the form was opened from" do
      patch envelope_reallocation_path(dentist), params: { reallocation: { date: "2026-11-03" }, from: "envelope", month: "2026-09", envelope: groceries.id }

      expect(dentist.reload.date).to eq(Date.new(2026, 11, 3))
      expect(response).to redirect_to(month_envelope_path("2026-11", groceries))
    end

    it "goes to the month view for the month of its date when it was opened from there, and when told to go anywhere else" do
      patch envelope_reallocation_path(dentist), params: { reallocation: { date: "2026-11-03" }, from: "month", month: "2026-09" }
      expect(response).to redirect_to(month_path("2026-11"))

      patch envelope_reallocation_path(dentist), params: { reallocation: { description: "Again" }, from: "https://evil.example/", month: "2026-09" }
      expect(response).to redirect_to(month_path("2026-11"))
    end

    it "keeps From when none is given" do
      patch envelope_reallocation_path(dentist), params: { reallocation: { description: "Dentist, again" } }

      expect(dentist.reload).to have_attributes(description: "Dentist, again", from_envelope: dining_out)
    end

    it "shows what's wrong, and keeps the form, for an invalid change" do
      patch envelope_reallocation_path(dentist),
        params: { reallocation: { description: "", amount: "-5" }, from: "envelope", month: "2026-09", envelope: groceries.id }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "form input[name=from][value=envelope]"
      assert_select "form input[name=envelope][value='#{groceries.id}']"
      assert_select "h1", text: "Edit reallocation"
      assert_select "p", text: "Groceries"
      expect(dentist.reload).to have_attributes(description: "Covering the dentist", amount: 20)
    end

    it "refuses the same envelope on both sides, and leaves the Reallocation where it was" do
      patch envelope_reallocation_path(dentist), params: { reallocation: { from_envelope_id: groceries.id }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "To can't be the same envelope as From"
      expect(dentist.reload.from_envelope).to eq(dining_out)
    end

    it "refuses another budget's envelope as From, as an error on the From field, and leaves the Reallocation where it was" do
      patch envelope_reallocation_path(dentist), params: { reallocation: { from_envelope_id: others_envelope.id }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "From can't be blank"
      assert_select "select[name='reallocation[from_envelope_id]'][aria-invalid=true]"
      expect(dentist.reload.from_envelope).to eq(dining_out)
      expect(response.body).not_to include("Someone else")
    end

    it "refuses a blank From, and leaves the Reallocation where it was" do
      patch envelope_reallocation_path(dentist), params: { reallocation: { from_envelope_id: "" }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "From can't be blank"
      expect(dentist.reload.from_envelope).to eq(dining_out)
    end

    it "has Cancel go back to the page of the envelope the Reallocation is still in or out of when a change of From is refused" do
      patch envelope_reallocation_path(dentist),
        params: { reallocation: { from_envelope_id: fuel.id, amount: "0" }, from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "select[name='reallocation[from_envelope_id]'] option[selected][value='#{fuel.id}']"
      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"
    end

    it "is not found for another user's Reallocation, which stays unchanged" do
      patch envelope_reallocation_path(others_reallocation), params: { reallocation: { description: "Mine now", from_envelope_id: groceries.id } }

      expect(response).to have_http_status(:not_found)
      expect(others_reallocation.reload).to have_attributes(description: "Someone else's", from_envelope: others_envelope)
    end
  end

  describe "DELETE /reallocations/to-envelope/:id" do
    it "deletes the Reallocation, and goes back to the month view for the month of its date" do
      expect { delete envelope_reallocation_path(dentist), params: { from: "month", month: "2026-10" } }
        .to change(Budget::EnvelopeReallocation, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Reallocation deleted."
    end

    it "goes back to the page of the envelope it was opened from, whichever side it was on" do
      delete envelope_reallocation_path(dentist), params: { from: "envelope", month: "2026-09", envelope: groceries.id }
      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))

      other = create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries, date: Date.new(2026, 9, 15))
      delete envelope_reallocation_path(other), params: { from: "envelope", month: "2026-09", envelope: dining_out.id }
      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
    end

    it "goes to the From envelope's page when the page it was opened from is not one of its envelopes" do
      delete envelope_reallocation_path(dentist), params: { from: "envelope", month: "2026-09", envelope: fuel.id }

      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
    end

    it "goes to the month view when it isn't told where to go back to" do
      delete envelope_reallocation_path(dentist)

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is not found for another user's Reallocation, which isn't deleted" do
      others_reallocation

      expect { delete envelope_reallocation_path(others_reallocation) }.not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
