require "rails_helper"

RSpec.describe "Spends", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:fuel) { create(:budget_envelope, budget: budget, name: "Fuel") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }

  before { sign_in_as budget.user }

  # What the envelope select offers, as one line of text per option.
  def choices
    css_select("select[name='spend[envelope_id]'] option").map { |option| option.text.strip }
  end

  describe "GET /spends/new" do
    before { travel_to Time.utc(2026, 9, 15, 16) }

    it "shows a form with a field for everything a Spend has" do
      get new_spend_path(month: "2026-09", from: "month")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "New spend · Budgie"
      assert_select "h1", text: "New spend"
      assert_select "form[action='#{spends_path}'][method=post]" do
        assert_select "label", text: "Envelope"
        assert_select "select[name='spend[envelope_id]'][required]"
        assert_select "label", text: "Description"
        assert_select "input[type=text][name='spend[description]'][required]"
        assert_select "p", text: "Such as Loblaws"
        assert_select "label", text: "Date"
        assert_select "input[type=date][name='spend[date]'][required]"
        assert_select "label", text: "Amount"
        assert_select "input[type=number][name='spend[amount]'][step='0.01'][required]"
        assert_select "label", text: "Notes"
        assert_select "textarea[name='spend[notes]']:not([required])"
        assert_select "input[type=submit]"
      end
    end

    it "offers the budget's envelopes alphabetically, after a prompt to choose one, and no one else's" do
      create(:budget_envelope, budget: budget, name: "bills")
      others_envelope

      get new_spend_path(month: "2026-09")

      expect(choices).to eq([ "Choose an envelope", "bills", "Fuel", "Groceries" ])
      assert_select "select[name='spend[envelope_id]'] option[value='']", text: "Choose an envelope"
      expect(response.body).not_to include("Someone else")
    end

    it "starts with no envelope chosen" do
      get new_spend_path(month: "2026-09")

      assert_select "option[selected]", count: 0
    end

    it "starts with the envelope it was opened for chosen, and no prompt to choose one" do
      get new_spend_path(month: "2026-09", from: "envelope", envelope: groceries.id)

      assert_select "option[selected][value='#{groceries.id}']", text: "Groceries"
      assert_select "option[selected]", count: 1
      expect(choices).to eq([ "Fuel", "Groceries" ])
    end

    it "doesn't choose another budget's envelope, or one that doesn't exist, or something that isn't an id" do
      [ others_envelope.id, 0, "not-an-id", "" ].each do |envelope_id|
        get new_spend_path(month: "2026-09", envelope: envelope_id)

        expect(response).to have_http_status(:ok)
        assert_select "option[selected]", count: 0
        expect(choices).to eq([ "Choose an envelope", "Fuel", "Groceries" ])
      end
    end

    it "starts with today's date when today is in the month it was opened from" do
      get new_spend_path(month: "2026-09")

      assert_select "input[name='spend[date]'][value='2026-09-15']"
    end

    it "starts with the 1st of the month it was opened from when today isn't in it" do
      get new_spend_path(month: "2027-03")

      assert_select "input[name='spend[date]'][value='2027-03-01']"
    end

    it "starts with today's date when it wasn't opened from a month" do
      get new_spend_path

      assert_select "input[name='spend[date]'][value='2026-09-15']"
    end

    it "carries the page and month it was opened from, so saving can go back" do
      get new_spend_path(month: "2026-09", from: "envelope", envelope: groceries.id)

      assert_select "form input[type=hidden][name=from][value=envelope]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
    end

    it "has a Cancel link back to the page it was opened from: the month view, or the envelope's page" do
      get new_spend_path(month: "2026-09", from: "month")
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"

      get new_spend_path(month: "2026-09", from: "envelope", envelope: groceries.id)
      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "goes back to the month view when it isn't told where it was opened from, or is told something else" do
      [ nil, "", "nowhere", "https://evil.example/", "//evil.example", "month/../../evil" ].each do |from|
        get new_spend_path(month: "2026-09", from: from)

        assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
        assert_select "form input[type=hidden][name=from]", count: 0
        expect(response.body).not_to include("evil")
      end
    end

    it "is not found for a month that isn't one" do
      get new_spend_path(month: "2026-13")

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get new_spend_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /spends" do
    let(:spend_params) do
      { envelope_id: groceries.id, description: "Loblaws", date: "2026-09-15", amount: "123.45", notes: "Weekly shop" }
    end

    it "adds a Spend to the chosen envelope, and goes to the month view for the month of its date" do
      expect { post spends_path, params: { spend: spend_params, from: "month", month: "2026-09" } }
        .to change(groceries.spends, :count).by(1)

      expect(groceries.spends.sole).to have_attributes(
        description: "Loblaws", date: Date.new(2026, 9, 15), amount: BigDecimal("123.45"), notes: "Weekly shop"
      )
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Spend added."
    end

    it "goes to the month of its date, not the month the form was opened from" do
      post spends_path, params: { spend: spend_params.merge(date: "2026-11-03"), from: "month", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-11"))
    end

    it "goes back to the page of the envelope it was added to when it was opened from an envelope's page" do
      post spends_path, params: { spend: spend_params.merge(envelope_id: fuel.id), from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-09", fuel))
    end

    it "goes to the envelope's page for the month of the Spend's date" do
      post spends_path, params: { spend: spend_params.merge(date: "2026-10-31"), from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-10", groceries))
    end

    it "goes to the home page for the current month when it was opened from there, and to the month's own address otherwise" do
      travel_to Time.utc(2026, 9, 15, 16)

      post spends_path, params: { spend: spend_params, from: "home", month: "2026-09" }
      expect(response).to redirect_to(root_path)

      post spends_path, params: { spend: spend_params.merge(date: "2026-08-20"), from: "home", month: "2026-09" }
      expect(response).to redirect_to(month_path("2026-08"))
    end

    it "goes to the month view when told to go anywhere else, or nowhere" do
      [ nil, "nowhere", "https://evil.example/", "//evil.example" ].each do |from|
        post spends_path, params: { spend: spend_params, from: from, month: "2026-09" }

        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "saves blank notes as an empty string" do
      post spends_path, params: { spend: spend_params.merge(notes: "") }

      expect(groceries.spends.sole.notes).to eq("")
    end

    # A date field takes a year of up to six digits, so a slip of the finger there still has to land somewhere.
    it "can be dated in a year with more than four digits, and still be found in its month" do
      post spends_path, params: { spend: spend_params.merge(date: "20266-09-15") }

      expect(response).to redirect_to(month_path("20266-09"))
      follow_redirect!
      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "September 20266"
    end

    it "shows what's wrong, and keeps what was typed, for an invalid Spend" do
      params = { spend: spend_params.merge(description: " ", amount: "0", notes: "Keep me"), from: "month", month: "2026-09" }

      expect { post spends_path, params: params }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "textarea[name='spend[notes]']", text: "Keep me"
      assert_select "input[name='spend[date]'][value='2026-09-15']"
      assert_select "option[selected][value='#{groceries.id}']"
      assert_select "form input[type=hidden][name=from][value=month]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "refuses more than 2 decimal places instead of rounding" do
      post spends_path, params: { spend: spend_params.merge(amount: "10.005") }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Amount can't have more than 2 decimal places"
    end

    it "shows a missing date as an error" do
      post spends_path, params: { spend: spend_params.merge(date: ""), month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Date can't be blank"
    end

    it "can't be saved without an envelope, and says so on the envelope field" do
      expect { post spends_path, params: { spend: spend_params.merge(envelope_id: ""), month: "2026-09" } }
        .not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      assert_select "select[name='spend[envelope_id]'][aria-invalid=true]"
      assert_select "p.text-error", text: "Envelope can't be blank"
      assert_select "option[selected]", count: 0
      assert_select "input[name='spend[description]'][value=Loblaws]"
    end

    it "can't be saved without the envelope at all" do
      expect { post spends_path, params: { spend: spend_params.except(:envelope_id) } }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
    end

    it "can't be saved against another budget's envelope: it's an error on the envelope field, and nothing is saved" do
      expect { post spends_path, params: { spend: spend_params.merge(envelope_id: others_envelope.id), month: "2026-09" } }
        .not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      assert_select "select[name='spend[envelope_id]'][aria-invalid=true]"
      expect(others_envelope.spends).to be_empty
      expect(response.body).not_to include("Someone else")
    end

    it "can't be saved against an envelope that doesn't exist, or something that isn't an id" do
      [ 0, "not-an-id", "1 OR 1=1" ].each do |envelope_id|
        expect { post spends_path, params: { spend: spend_params.merge(envelope_id: envelope_id) } }
          .not_to change(Budget::Spend, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "Envelope can't be blank"
      end
    end

    it "ignores an envelope or budget given any other way than the envelope's id" do
      post spends_path, params: { spend: spend_params.merge(envelope: others_envelope.id, budget_id: others_envelope.budget_id) }

      expect(groceries.spends.sole).to be_present
      expect(others_envelope.spends).to be_empty
    end

    it "is not found when the month it was opened from isn't one" do
      expect { post spends_path, params: { spend: spend_params, month: "2026-13" } }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /spends/:id/edit" do
    let(:loblaws) do
      create(:budget_spend, envelope: groceries, description: "Loblaws", date: Date.new(2026, 9, 30), amount: 123.45, notes: "Weekly shop")
    end

    it "shows the form for the user's Spend, filled in, with its envelope chosen" do
      get edit_spend_path(loblaws, month: "2026-09", from: "envelope")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit spend · Budgie"
      assert_select "h1", text: "Edit spend"
      assert_select "form[action='#{spend_path(loblaws)}'][method=post]" do
        assert_select "input[name='_method'][value=patch]"
        assert_select "option[selected][value='#{groceries.id}']", text: "Groceries"
        assert_select "input[name='spend[description]'][value=Loblaws]"
        assert_select "input[name='spend[date]'][value='2026-09-30']"
        assert_select "textarea[name='spend[notes]']", text: "Weekly shop"
      end
      expect(BigDecimal(css_select("input[name='spend[amount]']").first["value"])).to eq(BigDecimal("123.45"))
    end

    it "lets the envelope be changed to any of the budget's, and offers no one else's" do
      others_envelope

      get edit_spend_path(loblaws, month: "2026-09")

      expect(choices).to eq([ "Fuel", "Groceries" ])
    end

    it "offers to delete the Spend, behind a confirmation, and remembers where the form was opened from" do
      get edit_spend_path(loblaws, month: "2026-09", from: "envelope")

      assert_select "form[action='#{spend_path(loblaws)}'][data-turbo-confirm='Delete the Loblaws spend?']" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "input[name=from][value=envelope]"
        assert_select "input[name=month][value='2026-09']"
        assert_select "button", text: "Delete"
      end
    end

    it "has a Cancel link back to the page it was opened from, the envelope's page for the month" do
      get edit_spend_path(loblaws, month: "2026-09", from: "envelope")

      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "has a Cancel link to the month view when it was opened from there" do
      get edit_spend_path(loblaws, month: "2026-09", from: "month")

      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "is not found for another user's Spend" do
      get edit_spend_path(create(:budget_spend, envelope: others_envelope))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /spends/:id" do
    let(:loblaws) { create(:budget_spend, envelope: groceries, description: "Loblaws", date: Date.new(2026, 9, 15), amount: 100) }

    it "updates the Spend, and goes back to the page it was opened from" do
      patch spend_path(loblaws), params: { spend: { description: "Costco", amount: "250.5", notes: "Bulk" }, from: "envelope", month: "2026-09" }

      expect(loblaws.reload).to have_attributes(description: "Costco", amount: BigDecimal("250.5"), notes: "Bulk", envelope: groceries)
      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
      follow_redirect!
      assert_select "[role=status]", text: "Spend updated."
    end

    it "moves the Spend to another of the budget's envelopes, and goes to the page of the envelope it's in now" do
      patch spend_path(loblaws), params: { spend: { envelope_id: fuel.id }, from: "envelope", month: "2026-09" }

      expect(loblaws.reload.envelope).to eq(fuel)
      expect(response).to redirect_to(month_envelope_path("2026-09", fuel))
    end

    it "follows a changed date to the month it's dated in now, not the one the form was opened from" do
      patch spend_path(loblaws), params: { spend: { date: "2026-11-03" }, from: "envelope", month: "2026-09" }

      expect(loblaws.reload.date).to eq(Date.new(2026, 11, 3))
      expect(response).to redirect_to(month_envelope_path("2026-11", groceries))
    end

    it "goes to the month view for the month of its date when it was opened from there" do
      patch spend_path(loblaws), params: { spend: { date: "2026-11-03" }, from: "month", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-11"))
    end

    it "goes to the month view when told to go anywhere else" do
      patch spend_path(loblaws), params: { spend: { description: "Costco" }, from: "https://evil.example/", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "keeps the envelope when none is given" do
      patch spend_path(loblaws), params: { spend: { description: "Costco" } }

      expect(loblaws.reload).to have_attributes(description: "Costco", envelope: groceries)
    end

    it "shows what's wrong, and keeps the form, for an invalid change" do
      patch spend_path(loblaws), params: { spend: { description: "", amount: "-5" }, from: "envelope", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "form input[name=from][value=envelope]"
      assert_select "h1", text: "Edit spend"
      expect(loblaws.reload).to have_attributes(description: "Loblaws", amount: 100)
    end

    it "refuses another budget's envelope, as an error on the envelope field, and leaves the Spend where it was" do
      patch spend_path(loblaws), params: { spend: { envelope_id: others_envelope.id }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      assert_select "select[name='spend[envelope_id]'][aria-invalid=true]"
      expect(loblaws.reload.envelope).to eq(groceries)
      expect(others_envelope.spends).to be_empty
    end

    it "refuses a blank envelope, and leaves the Spend where it was" do
      patch spend_path(loblaws), params: { spend: { envelope_id: "" }, month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      expect(loblaws.reload.envelope).to eq(groceries)
    end

    it "is not found for another user's Spend, which stays unchanged" do
      others = create(:budget_spend, envelope: others_envelope, description: "Someone else's")

      patch spend_path(others), params: { spend: { description: "Mine now", envelope_id: groceries.id } }

      expect(response).to have_http_status(:not_found)
      expect(others.reload).to have_attributes(description: "Someone else's", envelope: others_envelope)
    end
  end

  describe "DELETE /spends/:id" do
    let!(:loblaws) { create(:budget_spend, envelope: groceries, description: "Loblaws", date: Date.new(2026, 9, 15)) }

    it "deletes the Spend, and goes back to the month view for the month of its date" do
      expect { delete spend_path(loblaws), params: { from: "month", month: "2026-10" } }
        .to change(Budget::Spend, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Spend deleted."
    end

    it "goes back to the page of the envelope it was in when it was opened from there, which is still there" do
      delete spend_path(loblaws), params: { from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-09", groceries))
    end

    it "goes to the month view when it isn't told where to go back to" do
      delete spend_path(loblaws)

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is not found for another user's Spend, which isn't deleted" do
      others = create(:budget_spend, envelope: others_envelope)

      expect { delete spend_path(others) }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the list of Spends" do
    it "is gone: a Spend is added from the month view or an envelope's page, and edited from the envelope's list" do
      spend = create(:budget_spend, envelope: groceries)

      get "/spends"
      expect(response).to have_http_status(:not_found)

      get "/spends/#{spend.id}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
