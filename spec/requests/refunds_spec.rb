require "rails_helper"

RSpec.describe "Refunds", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:fuel) { create(:budget_envelope, budget: budget, name: "Fuel") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }

  before { sign_in_as budget.user }

  # What the envelope select offers, as one line of text per option.
  def choices
    css_select("select[name='refund[envelope_id]'] option").map { |option| option.text.strip }
  end

  describe "GET /refunds/new" do
    before { travel_to Time.utc(2026, 9, 15, 16) }

    it "shows a form with a field for everything a Refund has" do
      get new_refund_path(month: "2026-09", from: "month")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "New refund · Budgie"
      assert_select "h1", text: "New refund"
      assert_select "form[action='#{refunds_path}'][method=post]" do
        assert_select "label", text: "Envelope"
        assert_select "select[name='refund[envelope_id]'][required]"
        assert_select "label", text: "Description"
        assert_select "input[type=text][name='refund[description]'][required]"
        assert_select "p", text: "Such as IKEA return"
        assert_select "label", text: "Date"
        assert_select "input[type=date][name='refund[date]'][required]"
        assert_select "label", text: "Amount"
        assert_select "input[type=number][name='refund[amount]'][step='0.01'][required]"
        assert_select "label", text: "Notes"
        assert_select "textarea[name='refund[notes]']:not([required])"
        assert_select "input[type=submit]"
      end
    end

    it "offers the budget's envelopes alphabetically, after a prompt to choose one, and no one else's" do
      create(:budget_envelope, budget: budget, name: "bills")
      others_envelope

      get new_refund_path(month: "2026-09")

      expect(choices).to eq([ "Choose an envelope", "bills", "Fuel", "Groceries" ])
      assert_select "select[name='refund[envelope_id]'] option[value='']", text: "Choose an envelope"
      expect(response.body).not_to include("Someone else")
    end

    it "starts with no envelope chosen" do
      get new_refund_path(month: "2026-09")

      assert_select "option[selected]", count: 0
    end

    it "starts with the envelope it was opened for chosen, and no prompt to choose one" do
      get new_refund_path(month: "2026-09", from: "envelope", envelope: groceries.id)

      assert_select "option[selected][value='#{groceries.id}']", text: "Groceries"
      assert_select "option[selected]", count: 1
      expect(choices).to eq([ "Fuel", "Groceries" ])
    end

    it "doesn't choose another budget's envelope, or one that doesn't exist, or something that isn't an id" do
      [ others_envelope.id, 0, "not-an-id", "", [ groceries.id ], { x: groceries.id } ].each do |envelope_id|
        get new_refund_path(month: "2026-09", envelope: envelope_id)

        expect(response).to have_http_status(:ok)
        assert_select "option[selected]", count: 0
        expect(choices).to eq([ "Choose an envelope", "Fuel", "Groceries" ])
      end
    end

    it "starts with today's date when today is in the month it was opened from" do
      get new_refund_path(month: "2026-09")

      assert_select "input[name='refund[date]'][value='2026-09-15']"
    end

    it "starts with the 1st of the month it was opened from when today isn't in it" do
      get new_refund_path(month: "2027-03")

      assert_select "input[name='refund[date]'][value='2027-03-01']"
    end

    it "starts with today's date when it wasn't opened from a month" do
      get new_refund_path

      assert_select "input[name='refund[date]'][value='2026-09-15']"
    end

    it "carries the page and month it was opened from, so saving can go back" do
      get new_refund_path(month: "2026-09", from: "envelope", envelope: groceries.id)

      assert_select "form input[type=hidden][name=from][value=envelope]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
    end

    it "has a Cancel link back to the page it was opened from: the month view, or the envelope's page" do
      get new_refund_path(month: "2026-09", from: "month")
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"

      get new_refund_path(month: "2026-09", from: "envelope", envelope: groceries.id)
      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "goes back to the month view when it isn't told where it was opened from, or is told something else" do
      [ nil, "", "nowhere", "https://evil.example/", "//evil.example", "month/../../evil" ].each do |from|
        get new_refund_path(month: "2026-09", from: from)

        assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
        assert_select "form input[type=hidden][name=from]", count: 0
        expect(response.body).not_to include("evil")
      end
    end

    it "is not found for a month that isn't one" do
      get new_refund_path(month: "2026-13")

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get new_refund_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /refunds" do
    let(:refund_params) do
      { envelope_id: groceries.id, description: "IKEA return", date: "2026-09-15", amount: "123.45", notes: "Bookcase" }
    end

    it "adds a Refund to the chosen envelope, and goes to the month view for the month of its date" do
      expect { post refunds_path, params: { refund: refund_params, from: "month", month: "2026-09" } }
        .to change(groceries.refunds, :count).by(1)

      expect(groceries.refunds.sole).to have_attributes(
        description: "IKEA return", date: Date.new(2026, 9, 15), amount: BigDecimal("123.45"), notes: "Bookcase"
      )
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Refund added."
    end

    it "goes to the month of its date, not the month the form was opened from" do
      post refunds_path, params: { refund: refund_params.merge(date: "2026-11-03"), from: "month", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-11"))
    end

    it "goes back to the page of the envelope it was added to when it was opened from an envelope's page" do
      post refunds_path, params: { refund: refund_params.merge(envelope_id: fuel.id), from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-09", fuel))
    end

    it "goes to the envelope's page for the month of the Refund's date" do
      post refunds_path, params: { refund: refund_params.merge(date: "2026-10-31"), from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-10", groceries))
    end

    it "goes to the home page for the current month when it was opened from there, and to the month's own address otherwise" do
      travel_to Time.utc(2026, 9, 15, 16)

      post refunds_path, params: { refund: refund_params, from: "home", month: "2026-09" }
      expect(response).to redirect_to(root_path)

      post refunds_path, params: { refund: refund_params.merge(date: "2026-08-20"), from: "home", month: "2026-09" }
      expect(response).to redirect_to(month_path("2026-08"))
    end

    it "goes to the month view when told to go anywhere else, or nowhere" do
      [ nil, "nowhere", "https://evil.example/", "//evil.example" ].each do |from|
        post refunds_path, params: { refund: refund_params, from: from, month: "2026-09" }

        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "saves blank notes as an empty string" do
      post refunds_path, params: { refund: refund_params.merge(notes: "") }

      expect(groceries.refunds.sole.notes).to eq("")
    end

    # A date field takes a year of up to six digits, so a slip of the finger there still has to land somewhere.
    it "can be dated in a year with more than four digits, and still be found in its month" do
      post refunds_path, params: { refund: refund_params.merge(date: "20266-09-15") }

      expect(response).to redirect_to(month_path("20266-09"))
      follow_redirect!
      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "September 20266"
    end

    it "shows what's wrong, and keeps what was typed, for an invalid Refund" do
      params = { refund: refund_params.merge(description: " ", amount: "0", notes: "Keep me"), from: "month", month: "2026-09" }

      expect { post refunds_path, params: params }.not_to change(Budget::Refund, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "textarea[name='refund[notes]']", text: "Keep me"
      assert_select "input[name='refund[date]'][value='2026-09-15']"
      assert_select "option[selected][value='#{groceries.id}']"
      assert_select "form input[type=hidden][name=from][value=month]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "refuses more than 2 decimal places instead of rounding" do
      post refunds_path, params: { refund: refund_params.merge(amount: "10.005") }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Amount can't have more than 2 decimal places"
    end

    it "shows a missing date as an error" do
      post refunds_path, params: { refund: refund_params.merge(date: ""), month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Date can't be blank"
    end

    it "can't be saved without an envelope, and says so on the envelope field" do
      expect { post refunds_path, params: { refund: refund_params.merge(envelope_id: ""), month: "2026-09" } }
        .not_to change(Budget::Refund, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      assert_select "select[name='refund[envelope_id]'][aria-invalid=true]"
      assert_select "p.text-error", text: "Envelope can't be blank"
      assert_select "option[selected]", count: 0
      assert_select "input[name='refund[description]'][value='IKEA return']"
    end

    it "can't be saved without the envelope at all" do
      expect { post refunds_path, params: { refund: refund_params.except(:envelope_id) } }.not_to change(Budget::Refund, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
    end

    it "can't be saved against another budget's envelope: it's an error on the envelope field, and nothing is saved" do
      expect { post refunds_path, params: { refund: refund_params.merge(envelope_id: others_envelope.id), month: "2026-09" } }
        .not_to change(Budget::Refund, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      assert_select "select[name='refund[envelope_id]'][aria-invalid=true]"
      expect(others_envelope.refunds).to be_empty
      expect(response.body).not_to include("Someone else")
    end

    it "can't be saved against an envelope that doesn't exist, or something that isn't an id" do
      [ 0, "not-an-id", "1 OR 1=1" ].each do |envelope_id|
        expect { post refunds_path, params: { refund: refund_params.merge(envelope_id: envelope_id) } }
          .not_to change(Budget::Refund, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "Envelope can't be blank"
      end
    end

    it "ignores an envelope or budget given any other way than the envelope's id" do
      post refunds_path, params: { refund: refund_params.merge(envelope: others_envelope.id, budget_id: others_envelope.budget_id) }

      expect(groceries.refunds.sole).to be_present
      expect(others_envelope.refunds).to be_empty
    end

    it "is not found when the month it was opened from isn't one" do
      expect { post refunds_path, params: { refund: refund_params, month: "2026-13" } }.not_to change(Budget::Refund, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /refunds/:id/edit" do
    let(:ikea) do
      create(:budget_refund, envelope: groceries, description: "IKEA return", date: Date.new(2026, 9, 30), amount: 123.45, notes: "Bookcase")
    end

    it "shows the form for the user's Refund, filled in, with its envelope chosen" do
      get edit_refund_path(ikea, month: "2026-09", from: "envelope")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit refund · Budgie"
      assert_select "h1", text: "Edit refund"
      assert_select "form[action='#{refund_path(ikea)}'][method=post]" do
        assert_select "input[name='_method'][value=patch]"
        assert_select "option[selected][value='#{groceries.id}']", text: "Groceries"
        assert_select "input[name='refund[description]'][value='IKEA return']"
        assert_select "input[name='refund[date]'][value='2026-09-30']"
        assert_select "textarea[name='refund[notes]']", text: "Bookcase"
      end
      expect(BigDecimal(css_select("input[name='refund[amount]']").first["value"])).to eq(BigDecimal("123.45"))
    end

    it "lets the envelope be changed to any of the budget's, and offers no one else's" do
      others_envelope

      get edit_refund_path(ikea, month: "2026-09")

      expect(choices).to eq([ "Fuel", "Groceries" ])
    end

    it "offers to delete the Refund, behind a confirmation, and remembers where the form was opened from" do
      get edit_refund_path(ikea, month: "2026-09", from: "envelope")

      assert_select "form[action='#{refund_path(ikea)}'][data-turbo-confirm='Delete the IKEA return refund?']" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "input[name=from][value=envelope]"
        assert_select "input[name=month][value='2026-09']"
        assert_select "button", text: "Delete"
      end
    end

    it "has a Cancel link back to the page it was opened from, the envelope's page for the month" do
      get edit_refund_path(ikea, month: "2026-09", from: "envelope")

      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "has a Cancel link to the month view when it was opened from there" do
      get edit_refund_path(ikea, month: "2026-09", from: "month")

      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "is not found for another user's Refund" do
      get edit_refund_path(create(:budget_refund, envelope: others_envelope))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /refunds/:id" do
    let(:ikea) { create(:budget_refund, envelope: groceries, description: "IKEA return", date: Date.new(2026, 9, 15), amount: 100) }

    it "updates the Refund, and goes back to the page it was opened from" do
      patch refund_path(ikea), params: { refund: { description: "Wayfair return", amount: "250.5", notes: "Bulk" }, from: "envelope", month: "2026-09" }

      expect(ikea.reload).to have_attributes(description: "Wayfair return", amount: BigDecimal("250.5"), notes: "Bulk", envelope: groceries)
      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
      follow_redirect!
      assert_select "[role=status]", text: "Refund updated."
    end

    it "moves the Refund to another of the budget's envelopes, and goes to the page of the envelope it's in now" do
      patch refund_path(ikea), params: { refund: { envelope_id: fuel.id }, from: "envelope", month: "2026-09" }

      expect(ikea.reload.envelope).to eq(fuel)
      expect(response).to redirect_to(month_envelope_path("2026-09", fuel))
    end

    it "follows a changed date to the month it's dated in now, not the one the form was opened from" do
      patch refund_path(ikea), params: { refund: { date: "2026-11-03" }, from: "envelope", month: "2026-09" }

      expect(ikea.reload.date).to eq(Date.new(2026, 11, 3))
      expect(response).to redirect_to(month_envelope_path("2026-11", groceries))
    end

    it "goes to the month view for the month of its date when it was opened from there" do
      patch refund_path(ikea), params: { refund: { date: "2026-11-03" }, from: "month", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-11"))
    end

    it "goes to the month view when told to go anywhere else" do
      patch refund_path(ikea), params: { refund: { description: "Wayfair return" }, from: "https://evil.example/", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "keeps the envelope when none is given" do
      patch refund_path(ikea), params: { refund: { description: "Wayfair return" } }

      expect(ikea.reload).to have_attributes(description: "Wayfair return", envelope: groceries)
    end

    it "shows what's wrong, and keeps the form, for an invalid change" do
      patch refund_path(ikea), params: { refund: { description: "", amount: "-5" }, from: "envelope", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "form input[name=from][value=envelope]"
      assert_select "h1", text: "Edit refund"
      expect(ikea.reload).to have_attributes(description: "IKEA return", amount: 100)
    end

    it "refuses another budget's envelope, as an error on the envelope field, and leaves the Refund where it was" do
      patch refund_path(ikea), params: { refund: { envelope_id: others_envelope.id }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      assert_select "select[name='refund[envelope_id]'][aria-invalid=true]"
      expect(ikea.reload.envelope).to eq(groceries)
      expect(others_envelope.refunds).to be_empty
    end

    it "has Cancel go back to the page of the envelope the Refund is still in when a move to another is refused" do
      patch refund_path(ikea), params: { refund: { envelope_id: fuel.id, amount: "0" }, from: "envelope", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "option[selected][value='#{fuel.id}']"
      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "has Cancel go back to the page of the envelope the Refund is in when the envelope it was moved to is refused" do
      patch refund_path(ikea), params: { refund: { envelope_id: others_envelope.id }, from: "envelope", month: "2026-09" }

      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "refuses a blank envelope, and leaves the Refund where it was" do
      patch refund_path(ikea), params: { refund: { envelope_id: "" }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      expect(ikea.reload.envelope).to eq(groceries)
    end

    it "is not found for another user's Refund, which stays unchanged" do
      others = create(:budget_refund, envelope: others_envelope, description: "Someone else's")

      patch refund_path(others), params: { refund: { description: "Mine now", envelope_id: groceries.id } }

      expect(response).to have_http_status(:not_found)
      expect(others.reload).to have_attributes(description: "Someone else's", envelope: others_envelope)
    end
  end

  describe "DELETE /refunds/:id" do
    let!(:ikea) { create(:budget_refund, envelope: groceries, description: "IKEA return", date: Date.new(2026, 9, 15)) }

    it "deletes the Refund, and goes back to the month view for the month of its date" do
      expect { delete refund_path(ikea), params: { from: "month", month: "2026-10" } }
        .to change(Budget::Refund, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Refund deleted."
    end

    it "goes back to the page of the envelope it was in when it was opened from there, which is still there" do
      delete refund_path(ikea), params: { from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
    end

    it "goes to the month view when it isn't told where to go back to" do
      delete refund_path(ikea)

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is not found for another user's Refund, which isn't deleted" do
      others = create(:budget_refund, envelope: others_envelope)

      expect { delete refund_path(others) }.not_to change(Budget::Refund, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the list of Refunds" do
    it "is gone: a Refund is added from an envelope's page, and edited from its list there" do
      refund = create(:budget_refund, envelope: groceries)

      get "/refunds"
      expect(response).to have_http_status(:not_found)

      get "/refunds/#{refund.id}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
