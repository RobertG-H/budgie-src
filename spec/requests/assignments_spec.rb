require "rails_helper"

RSpec.describe "Assignments", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 25) }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }
  let(:september) { Date.new(2026, 9, 1) }
  # What the Assigned cell's frame is called, and so what a request from inside it says it's after.
  let(:frame) { "assigned_envelope_#{groceries.id}" }
  # The ids of the input, and of the reason it was refused, which are each envelope's own, so that more than one
  # cell can be open on the month view at once.
  let(:amount_id) { "envelope_#{groceries.id}_assignment_amount" }

  before { sign_in_as budget.user }

  # What the envelope has assigned, as [ month, amount ] pairs.
  def assigned(envelope = groceries)
    Budget::Assignment.where(envelope: envelope).order(:month).pluck(:month, :amount)
  end

  describe "GET /months/:month/envelopes/:envelope_id/assignment/edit" do
    it "is the input for the amount, labelled for the envelope and month, in the frame the Assigned cell is in" do
      get edit_month_envelope_assignment_path("2026-09", groceries), headers: { "Turbo-Frame" => frame }

      expect(response).to have_http_status(:ok)
      assert_select "turbo-frame##{frame}" do
        assert_select "form[action='#{month_envelope_assignment_path("2026-09", groceries)}'][method=post]" do
          assert_select "input[name=_method][value=patch]"
          assert_select "label.sr-only[for=#{amount_id}]", text: "Assigned to Groceries in September 2026"
          assert_select "input##{amount_id}[type=number][name='assignment[amount]'][step='0.01'][autofocus]"
        end
      end
    end

    it "submits to the whole page, so that saving can refresh the month view, and has Save and Cancel" do
      get edit_month_envelope_assignment_path("2026-09", groceries), headers: { "Turbo-Frame" => frame }

      assert_select "form[data-turbo-frame='_top']" do
        assert_select "input[type=submit][value=Save].btn-primary"
        assert_select "a.btn[href='#{month_envelope_assignment_path("2026-09", groceries)}']", text: "Cancel"
      end
    end

    it "remembers the page it was opened from, and the month, so that saving can go back to them, and Cancel keeps both" do
      get edit_month_envelope_assignment_path("2026-09", groceries, from: "home"), headers: { "Turbo-Frame" => frame }

      assert_select "form[data-turbo-frame='_top']" do
        assert_select "input[type=hidden][name=from][value=home]"
        assert_select "input[type=hidden][name=month][value='2026-09']"
        assert_select "a.btn[href='#{month_envelope_assignment_path("2026-09", groceries, from: "home")}']", text: "Cancel"
      end
    end

    it "has no page to go back to unless it was told one that is a page's name" do
      [ nil, "https://evil.example/", "nowhere" ].each do |from|
        get edit_month_envelope_assignment_path("2026-09", groceries, from: from), headers: { "Turbo-Frame" => frame }

        assert_select "form input[name=from]", count: 0
        assert_select "form input[type=hidden][name=month][value='2026-09']"
        assert_select "form a.btn[href='#{month_envelope_assignment_path("2026-09", groceries)}']", text: "Cancel"
      end
    end

    it "starts empty when nothing is assigned, and with the amount when something is" do
      get edit_month_envelope_assignment_path("2026-09", groceries), headers: { "Turbo-Frame" => frame }
      assert_select "input##{amount_id}[value]", count: 0

      create(:budget_assignment, envelope: groceries, month: september, amount: 400)
      get edit_month_envelope_assignment_path("2026-09", groceries), headers: { "Turbo-Frame" => frame }
      assert_select "input##{amount_id}[value='400.0']"
    end

    it "asks about the month it's for, not another's" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 10, 1), amount: 400)

      get edit_month_envelope_assignment_path("2026-09", groceries), headers: { "Turbo-Frame" => frame }

      assert_select "input##{amount_id}[value]", count: 0
      assert_select "label.sr-only", text: "Assigned to Groceries in September 2026"
    end

    it "gives each envelope's input its own ids, with the reason it was refused, so a second cell can be opened before the first is closed" do
      rent = create(:budget_envelope, budget: budget, name: "Rent")

      ids = [ groceries, rent ].map do |envelope|
        patch month_envelope_assignment_path("2026-09", envelope), params: { assignment: { amount: "-5" } }
        css_select("[id]").map { |element| element["id"] }
      end

      expect(ids.first).to include("envelope_#{groceries.id}_assignment_amount", "envelope_#{groceries.id}_assignment_amount_error")
      expect(ids.last).to include("envelope_#{rent.id}_assignment_amount", "envelope_#{rent.id}_assignment_amount_error")
      expect(ids.first & ids.last).to be_empty
    end

    it "is a whole page, with the input in it, when it isn't asked for from a frame" do
      get edit_month_envelope_assignment_path("2026-09", groceries)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Assigned to Groceries · September 2026 · Budgie"
      assert_select "header", text: /Budgie/
      assert_select "main turbo-frame##{frame} form input[name='assignment[amount]']"
    end
  end

  describe "GET /months/:month/envelopes/:envelope_id/assignment" do
    it "is the button showing what's Assigned, in the frame, for Cancel to go back to" do
      create(:budget_assignment, envelope: groceries, month: september, amount: 1234.5)

      get month_envelope_assignment_path("2026-09", groceries), headers: { "Turbo-Frame" => frame }

      expect(response).to have_http_status(:ok)
      assert_select "turbo-frame##{frame}" do
        assert_select "form[method=get][action='#{edit_month_envelope_assignment_path("2026-09", groceries)}'] button.btn", text: /\$1,234\.50/
      end
    end

    it "shows $0.00 when nothing is assigned for the month" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 10, 1), amount: 99)

      get month_envelope_assignment_path("2026-09", groceries), headers: { "Turbo-Frame" => frame }

      assert_select "turbo-frame##{frame} button.btn", text: /\$0\.00/
    end

    it "keeps the page it was opened from in its button, for the next time it's pressed" do
      get month_envelope_assignment_path("2026-09", groceries, from: "home"), headers: { "Turbo-Frame" => frame }

      assert_select "turbo-frame##{frame} form[method=get] input[type=hidden][name=from][value=home]"
    end

    it "goes to the month view when it isn't asked for from a frame" do
      get month_envelope_assignment_path("2026-09", groceries)

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "goes to the page it was opened from when it isn't asked for from a frame, which for the home page is the home page" do
      travel_to Time.utc(2026, 9, 15, 16)

      get month_envelope_assignment_path("2026-09", groceries, from: "home")

      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH /months/:month/envelopes/:envelope_id/assignment" do
    # `from` is the page the form was opened from, as the form says: its hidden field.
    def assign(amount, month: "2026-09", envelope: groceries, from: nil, **options)
      params = { assignment: { amount: amount } }
      params[:from] = from if from
      patch month_envelope_assignment_path(month, envelope), params: params, **options
    end

    it "sets what's Assigned, and goes back to the month view for the month that was edited" do
      assign "400.50"

      expect(assigned).to eq([ [ september, BigDecimal("400.50") ] ])
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_path("2026-09"))
    end

    # The current month is the home page as well as /months/YYYY-MM, and Turbo only refreshes a page in place when the
    # redirect is to the address it's already at. So a form opened from the home page goes back to the home page, as
    # every form goes back to the page it was opened from (ReturnsToOrigin).
    describe "going back to the page it was opened from" do
      # September 15 in Eastern time, so September 2026 is the current month.
      before { travel_to Time.utc(2026, 9, 15, 16) }

      it "is the home page, for the current month, when it was opened from the home page, which is the page to refresh" do
        assign "5", from: "home"

        expect(response).to redirect_to(root_path)
        expect(assigned).to eq([ [ september, 5 ] ])
      end

      it "is the month's own address when it was opened from there, even for the current month" do
        assign "5", from: "month"

        expect(response).to redirect_to(month_path("2026-09"))
      end

      it "is the month's own address for any other month, since the home page isn't that month's page" do
        assign "5", month: "2026-08", from: "home"

        expect(response).to redirect_to(month_path("2026-08"))
      end

      it "is the month that was edited when the home page has gone out of date, having been left open past the end of a month" do
        travel_to Time.utc(2026, 10, 1, 16)

        assign "5", month: "2026-09", from: "home"

        expect(response).to redirect_to(month_path("2026-09"))
      end

      it "is the month's own address when it wasn't told a page, or was told something that isn't a page's name" do
        [ nil, "", "envelope", "root", "https://evil.example/", "//evil.example", "/" ].each do |from|
          assign "5", from: from

          expect(response).to redirect_to(month_path("2026-09"))
        end
      end

      it "takes nothing from the Referer, which has nothing to do with where it goes" do
        assign "5", headers: { "Referer" => root_url }

        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "is for any month, in the past or the future, and goes back to that month" do
      assign "10", month: "2024-01"
      expect(response).to redirect_to(month_path("2024-01"))

      assign "20", month: "2031-12"
      expect(response).to redirect_to(month_path("2031-12"))

      expect(assigned).to eq([ [ Date.new(2024, 1, 1), 10 ], [ Date.new(2031, 12, 1), 20 ] ])
    end

    it "changes what's Assigned, in the one Assignment for the month" do
      create(:budget_assignment, envelope: groceries, month: september, amount: 100)

      assign "250"

      expect(assigned).to eq([ [ september, 250 ] ])
      expect(response).to redirect_to(month_path("2026-09"))
    end

    [ "", " ", "0", "0.00" ].each do |nothing|
      it "clears what's Assigned for #{nothing.inspect}, deleting the Assignment" do
        create(:budget_assignment, envelope: groceries, month: september, amount: 100)
        create(:budget_assignment, envelope: groceries, month: Date.new(2026, 10, 1), amount: 5)

        assign nothing

        expect(assigned).to eq([ [ Date.new(2026, 10, 1), 5 ] ])
        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "is fine with clearing what was never assigned" do
      assign ""

      expect(assigned).to be_empty
      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is fine with a double submit: the second changes the Assignment the first made" do
      2.times { assign "400" }

      expect(assigned).to eq([ [ september, 400 ] ])
      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "doesn't say anything with a notice: the figures changing are the answer" do
      assign "400"
      follow_redirect!

      assert_select "[role=status]", count: 0
    end

    {
      "-5" => "Assigned must be greater than 0",
      "10.005" => "Assigned can't have more than 2 decimal places",
      "10000000000000" => "Assigned must be less than 10000000000000"
    }.each do |refused, message|
      it "refuses #{refused.inspect}, keeping what's Assigned, and shows the input again with the reason" do
        create(:budget_assignment, envelope: groceries, month: september, amount: 100)

        assign refused

        expect(response).to have_http_status(:unprocessable_content)
        expect(assigned).to eq([ [ september, 100 ] ])
        assert_select "form[action='#{month_envelope_assignment_path("2026-09", groceries)}']" do
          assert_select "input##{amount_id}[aria-invalid=true][value='#{refused}'][aria-describedby=#{amount_id}_error]"
          assert_select "p##{amount_id}_error", text: message
          assert_select "label.sr-only", text: "Assigned to Groceries in September 2026"
          assert_select "input[type=submit][value=Save]"
        end
      end
    end

    it "puts the input back in the frame, as a Turbo Stream, when the page asked for one" do
      assign "-5", headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      assert_select "turbo-stream[action=update][target=#{frame}] template" do
        assert_select "form input##{amount_id}[aria-invalid=true][value='-5']"
        assert_select "p##{amount_id}_error", text: "Assigned must be greater than 0"
      end
    end

    it "creates nothing for a month with no Assignment when the amount is refused" do
      assign "-5"

      expect(assigned).to be_empty
    end

    it "is not found for another user's envelope, whose Assignments are left alone" do
      create(:budget_assignment, envelope: others_envelope, month: september, amount: 100)

      assign "5", envelope: others_envelope

      expect(response).to have_http_status(:not_found)
      expect(assigned(others_envelope)).to eq([ [ september, 100 ] ])
    end

    it "is not found for an envelope that doesn't exist, or a month that isn't one" do
      patch "/months/2026-09/envelopes/0/assignment", params: { assignment: { amount: "5" } }
      expect(response).to have_http_status(:not_found)

      patch "/months/2026-09/envelopes/not-an-id/assignment", params: { assignment: { amount: "5" } }
      expect(response).to have_http_status(:not_found)

      patch "/months/2026-13/envelopes/#{groceries.id}/assignment", params: { assignment: { amount: "5" } }
      expect(response).to have_http_status(:not_found)
      expect(assigned).to be_empty
    end

    it "is a bad request without an amount to set" do
      patch month_envelope_assignment_path("2026-09", groceries)

      expect(response).to have_http_status(:bad_request)
      expect(assigned).to be_empty
    end

    it "ignores an envelope_id or a month in the params, which come from the URL" do
      other = create(:budget_envelope, budget: budget, name: "Rent")

      patch month_envelope_assignment_path("2026-09", groceries),
        params: { assignment: { amount: "5", envelope_id: other.id, month: "2030-01-01" } }

      expect(assigned).to eq([ [ september, 5 ] ])
      expect(assigned(other)).to be_empty
    end

    it "also answers PUT, as a singular resource does" do
      put month_envelope_assignment_path("2026-09", groceries), params: { assignment: { amount: "5" } }

      expect(assigned).to eq([ [ september, 5 ] ])
    end
  end

  describe "signing in" do
    it "is needed for every action" do
      delete session_path

      get edit_month_envelope_assignment_path("2026-09", groceries)
      expect(response).to redirect_to(sign_in_path)

      get month_envelope_assignment_path("2026-09", groceries)
      expect(response).to redirect_to(sign_in_path)

      patch month_envelope_assignment_path("2026-09", groceries), params: { assignment: { amount: "5" } }
      expect(response).to redirect_to(sign_in_path)
      expect(assigned).to be_empty
    end
  end

  describe "the other user's envelope" do
    it "is not found to edit or show either" do
      get edit_month_envelope_assignment_path("2026-09", others_envelope)
      expect(response).to have_http_status(:not_found)

      get month_envelope_assignment_path("2026-09", others_envelope), headers: { "Turbo-Frame" => "assigned_envelope_#{others_envelope.id}" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
