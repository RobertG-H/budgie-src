require "rails_helper"

# The Reallocate form, which makes a Reallocation between two envelopes. Editing and deleting one are in
# envelope_reallocations_spec.rb.
RSpec.describe "Reallocations", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }

  before { sign_in_as budget.user }

  # What a select offers, as one line of text per option.
  def choices(side)
    css_select("select[name='reallocation[#{side}_envelope_id]'] option").map { |option| option.text.strip }
  end

  describe "GET /reallocations/new" do
    before { travel_to Time.utc(2026, 9, 15, 16) }

    it "shows a form with a field for everything a Reallocation has" do
      get new_reallocation_path(month: "2026-09", from: "month")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Reallocate · Budgie"
      assert_select "h1", text: "Reallocate"
      assert_select "form[action='#{reallocations_path}'][method=post]" do
        assert_select "label", text: "From"
        assert_select "select[name='reallocation[from_envelope_id]'][required]"
        assert_select "label", text: "To"
        assert_select "select[name='reallocation[to_envelope_id]'][required]"
        assert_select "label", text: "Description"
        assert_select "input[type=text][name='reallocation[description]'][required]"
        assert_select "p", text: "Such as Covering the dentist"
        assert_select "label", text: "Date"
        assert_select "input[type=date][name='reallocation[date]'][required]"
        assert_select "label", text: "Amount"
        assert_select "input[type=number][name='reallocation[amount]'][step='0.01'][required]"
        assert_select "label", text: "Notes"
        assert_select "textarea[name='reallocation[notes]']:not([required])"
        assert_select "input[type=submit][value='Create Reallocation']"
      end
    end

    it "offers the budget's envelopes alphabetically on both sides, after a prompt to choose one, and no one else's" do
      create(:budget_envelope, budget: budget, name: "bills")
      others_envelope

      get new_reallocation_path(month: "2026-09")

      expect(choices(:from)).to eq([ "Choose an envelope", "bills", "Dining out", "Groceries" ])
      expect(choices(:to)).to eq([ "Choose an envelope", "bills", "Dining out", "Groceries" ])
      expect(response.body).not_to include("Someone else")
    end

    it "starts with no envelope chosen on either side, and the focus on From" do
      get new_reallocation_path(month: "2026-09")

      assert_select "option[selected]", count: 0
      assert_select "select[name='reallocation[from_envelope_id]'][autofocus]"
      assert_select "select[name='reallocation[to_envelope_id]'][autofocus]", count: 0
    end

    it "starts with the envelope it was opened for as From, and the focus on To" do
      get new_reallocation_path(month: "2026-09", from: "envelope", envelope: dining_out.id)

      assert_select "select[name='reallocation[from_envelope_id]'] option[selected][value='#{dining_out.id}']", text: "Dining out"
      assert_select "select[name='reallocation[to_envelope_id]'] option[selected]", count: 0
      assert_select "select[name='reallocation[to_envelope_id]'][autofocus]"
      assert_select "select[name='reallocation[from_envelope_id]'][autofocus]", count: 0
    end

    it "doesn't choose another budget's envelope, or one that doesn't exist, or something that isn't an id" do
      [ others_envelope.id, 0, "not-an-id", "", [ dining_out.id ], { x: dining_out.id } ].each do |envelope_id|
        get new_reallocation_path(month: "2026-09", from: "envelope", envelope: envelope_id)

        expect(response).to have_http_status(:ok)
        assert_select "option[selected]", count: 0
        assert_select "input[name=envelope]", count: 0
        expect(choices(:from)).to eq([ "Choose an envelope", "Dining out", "Groceries" ])
      end
    end

    it "starts with today's date when today is in the month it was opened from, and otherwise the 1st of that month" do
      get new_reallocation_path(month: "2026-09")
      assert_select "input[name='reallocation[date]'][value='2026-09-15']"

      get new_reallocation_path(month: "2027-03")
      assert_select "input[name='reallocation[date]'][value='2027-03-01']"
    end

    it "carries the page and month it was opened from, and the envelope whose page that was, so saving can go back" do
      get new_reallocation_path(month: "2026-09", from: "envelope", envelope: dining_out.id)

      assert_select "form input[type=hidden][name=from][value=envelope]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
      assert_select "form input[type=hidden][name=envelope][value='#{dining_out.id}']"
    end

    it "has a Cancel link back to the page it was opened from: the month view, or the envelope's page" do
      get new_reallocation_path(month: "2026-09", from: "month")
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"

      get new_reallocation_path(month: "2026-09", from: "envelope", envelope: dining_out.id)
      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"
    end

    it "goes back to the month view when it isn't told where it was opened from, or is told something else" do
      [ nil, "", "nowhere", "https://evil.example/", "//evil.example" ].each do |from|
        get new_reallocation_path(month: "2026-09", from: from, envelope: dining_out.id)

        assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
        assert_select "form input[type=hidden][name=from]", count: 0
        expect(response.body).not_to include("evil")
      end
    end

    it "is not found for a month that isn't one" do
      get new_reallocation_path(month: "2026-13")

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get new_reallocation_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /reallocations" do
    let(:reallocation_params) do
      {
        from_envelope_id: dining_out.id, to_envelope_id: groceries.id,
        description: "Covering the dentist", date: "2026-09-15", amount: "20.50", notes: "Just this once"
      }
    end

    it "adds a Reallocation from the one envelope to the other, and goes to the month view for the month of its date" do
      expect { post reallocations_path, params: { reallocation: reallocation_params, from: "month", month: "2026-09" } }
        .to change(Budget::EnvelopeReallocation, :count).by(1)

      expect(Budget::EnvelopeReallocation.sole).to have_attributes(
        from_envelope: dining_out, to_envelope: groceries, description: "Covering the dentist",
        date: Date.new(2026, 9, 15), amount: BigDecimal("20.5"), notes: "Just this once"
      )
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Reallocation added."
    end

    it "goes to the month of its date, not the month the form was opened from" do
      post reallocations_path, params: { reallocation: reallocation_params.merge(date: "2026-11-03"), from: "month", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-11"))
    end

    it "goes back to the page of the envelope it was opened from, for the month of its date" do
      post reallocations_path, params: { reallocation: reallocation_params.merge(date: "2026-10-31"), from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect(response).to redirect_to(month_envelope_path("2026-10", dining_out))
    end

    it "goes back to the To envelope's page when the form was opened from there" do
      post reallocations_path, params: { reallocation: reallocation_params, from: "envelope", month: "2026-09", envelope: groceries.id }

      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
    end

    it "goes to the From envelope's page when the form was opened from the page of an envelope it isn't in or out of" do
      fuel = create(:budget_envelope, budget: budget, name: "Fuel")

      post reallocations_path, params: { reallocation: reallocation_params, from: "envelope", month: "2026-09", envelope: fuel.id }

      expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
    end

    it "goes to the From envelope's page when from=envelope but no envelope's page was named, or one that isn't the budget's" do
      [ {}, { envelope: others_envelope.id }, { envelope: "nope" } ].each do |extra|
        post reallocations_path, params: { reallocation: reallocation_params, from: "envelope", month: "2026-09" }.merge(extra)

        expect(response).to redirect_to(month_envelope_path("2026-09", dining_out))
      end
    end

    it "goes to the home page for the current month when it was opened from there, and to the month's own address otherwise" do
      travel_to Time.utc(2026, 9, 15, 16)

      post reallocations_path, params: { reallocation: reallocation_params, from: "home", month: "2026-09" }
      expect(response).to redirect_to(root_path)

      post reallocations_path, params: { reallocation: reallocation_params.merge(date: "2026-08-20"), from: "home", month: "2026-09" }
      expect(response).to redirect_to(month_path("2026-08"))
    end

    it "goes to the month view when told to go anywhere else, or nowhere" do
      [ nil, "nowhere", "https://evil.example/", "//evil.example" ].each do |from|
        post reallocations_path, params: { reallocation: reallocation_params, from: from, month: "2026-09" }

        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "saves blank notes as an empty string" do
      post reallocations_path, params: { reallocation: reallocation_params.merge(notes: "") }

      expect(Budget::EnvelopeReallocation.sole.notes).to eq("")
    end

    it "may be more than the From envelope has Available, which leaves it Overspent" do
      post reallocations_path, params: { reallocation: reallocation_params.merge(amount: "5000"), month: "2026-09" }

      expect(Budget::EnvelopeReallocation.sole.amount).to eq(5000)
      get month_envelope_path("2026-09", dining_out)
      assert_select ".badge", text: "Overspent"
    end

    it "shows what's wrong, and keeps what was typed, for an invalid Reallocation" do
      params = { reallocation: reallocation_params.merge(description: " ", amount: "0", notes: "Keep me"), from: "envelope", month: "2026-09", envelope: dining_out.id }

      expect { post reallocations_path, params: params }.not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "textarea[name='reallocation[notes]']", text: "Keep me"
      assert_select "input[name='reallocation[date]'][value='2026-09-15']"
      assert_select "select[name='reallocation[from_envelope_id]'] option[selected][value='#{dining_out.id}']"
      assert_select "select[name='reallocation[to_envelope_id]'] option[selected][value='#{groceries.id}']"
      assert_select "form input[type=hidden][name=from][value=envelope]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
      assert_select "form input[type=hidden][name=envelope][value='#{dining_out.id}']"
      assert_select "a.btn[href='#{month_envelope_path("2026-09", dining_out)}']", text: "Cancel"
    end

    it "refuses more than 2 decimal places instead of rounding" do
      post reallocations_path, params: { reallocation: reallocation_params.merge(amount: "10.005") }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Amount can't have more than 2 decimal places"
    end

    it "can't be saved without a From, and says so on the From field" do
      [ { from_envelope_id: "" }, { from_envelope_id: nil } ].each do |blank|
        expect { post reallocations_path, params: { reallocation: reallocation_params.merge(blank), month: "2026-09" } }
          .not_to change(Budget::EnvelopeReallocation, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "From can't be blank"
        assert_select "select[name='reallocation[from_envelope_id]'][aria-invalid=true]"
        assert_select "p.text-error", text: "From can't be blank"
        assert_select "input[name='reallocation[description]'][value='Covering the dentist']"
      end
    end

    it "can't be saved without a To, and says so on the To field" do
      expect { post reallocations_path, params: { reallocation: reallocation_params.merge(to_envelope_id: ""), month: "2026-09" } }
        .not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "To can't be blank"
      assert_select "select[name='reallocation[to_envelope_id]'][aria-invalid=true]"
      assert_select "p.text-error", text: "To can't be blank"
    end

    it "can't be saved without the envelopes at all" do
      expect { post reallocations_path, params: { reallocation: reallocation_params.except(:from_envelope_id, :to_envelope_id) } }
        .not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "From can't be blank"
      assert_select "[role=alert] li", text: "To can't be blank"
    end

    it "can't be saved with the same envelope on both sides" do
      expect { post reallocations_path, params: { reallocation: reallocation_params.merge(to_envelope_id: dining_out.id) } }
        .not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "To can't be the same envelope as From"
      assert_select "p.text-error", text: "To can't be the same envelope as From"
    end

    it "can't be saved from another budget's envelope: it's an error on the From field, and nothing is saved" do
      expect { post reallocations_path, params: { reallocation: reallocation_params.merge(from_envelope_id: others_envelope.id) } }
        .not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "From can't be blank"
      assert_select "select[name='reallocation[from_envelope_id]'][aria-invalid=true]"
      expect(response.body).not_to include("Someone else")
    end

    it "can't be saved to another budget's envelope: it's an error on the To field, and nothing is saved" do
      expect { post reallocations_path, params: { reallocation: reallocation_params.merge(to_envelope_id: others_envelope.id) } }
        .not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "To can't be blank"
      assert_select "select[name='reallocation[to_envelope_id]'][aria-invalid=true]"
      expect(response.body).not_to include("Someone else")
    end

    it "can't be saved with an envelope that doesn't exist, or something that isn't an id" do
      [ 0, "not-an-id", "1 OR 1=1" ].each do |envelope_id|
        [ :from_envelope_id, :to_envelope_id ].each do |side|
          expect { post reallocations_path, params: { reallocation: reallocation_params.merge(side => envelope_id) } }
            .not_to change(Budget::EnvelopeReallocation, :count)

          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end

    it "ignores an envelope or budget given any other way than the envelopes' ids" do
      post reallocations_path, params: { reallocation: reallocation_params.merge(from_envelope: others_envelope.id, budget_id: others_envelope.budget_id) }

      expect(Budget::EnvelopeReallocation.sole).to have_attributes(from_envelope: dining_out, to_envelope: groceries)
    end

    it "is not found when the month it was opened from isn't one" do
      expect { post reallocations_path, params: { reallocation: reallocation_params, month: "2026-13" } }
        .not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      expect { post reallocations_path, params: { reallocation: reallocation_params } }.not_to change(Budget::EnvelopeReallocation, :count)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "the list of Reallocations" do
    it "is gone: a Reallocation is added from the Reallocate form, and edited from an envelope's page" do
      reallocation = create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries)

      get "/reallocations"
      expect(response).to have_http_status(:not_found)

      get "/reallocations/#{reallocation.id}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
