require "rails_helper"

RSpec.describe "Months", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }

  before { sign_in_as budget.user }

  # The words under Ready to Assign's number. Its amounts are spans of their own, so the whitespace between the
  # pieces is collapsed before comparing.
  def stat_description
    css_select(".stat-desc:not(.text-error)").map { |description| description.text.squish }.sole
  end

  # The amount an envelope's Assigned button shows, without the words that name the button for assistive technology.
  def assigned_for(envelope)
    css_select("tr#envelope_#{envelope.id} td:nth-child(3) button span:not(.sr-only)").map { |amount| amount.text.strip }.sole
  end

  describe "GET /" do
    it "opens the current month, by Eastern time" do
      # 00:30 UTC on October 1 is still the evening of September 30 in Eastern time.
      travel_to Time.utc(2026, 10, 1, 0, 30)

      get root_path

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "September 2026"
      assert_select "title", text: "September 2026 · Budgie"
    end

    it "is the month view for a user who has a budget, and nothing else" do
      get root_path

      expect(response).to have_http_status(:ok)
      assert_select "h1", count: 1
    end
  end

  describe "GET /months/:month" do
    it "shows the month it names, whatever today is" do
      get month_path("2031-02")

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "February 2031"
      assert_select "title", text: "February 2031 · Budgie"
    end

    it "isn't bounded in either direction" do
      get month_path("0001-01")
      expect(response).to have_http_status(:ok)

      get month_path("9999-12")
      expect(response).to have_http_status(:ok)
      assert_select "nav[aria-label=Months] a[rel=next]", text: "January 10000"

      click_next = css_select("nav[aria-label=Months] a[rel=next]").first["href"]
      get click_next
      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "January 10000"
    end

    [ "2026-13", "2026-00", "2026-9", "2026-09-01", "0000-05", "1000000-01", "abc" ].each do |param|
      it "is not found for #{param.inspect}, which isn't a month" do
        get "/months/#{param}"

        expect(response).to have_http_status(:not_found)
      end
    end

    it "requires sign-in" do
      delete session_path

      get month_path("2026-09")

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "Ready to Assign" do
    it "is every Deposit for the month and before it, with what was carried over and deposited, linking to the month's Deposits" do
      create(:budget_deposit, budget: budget, amount: 1000, date: Date.new(2026, 8, 1))
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 1))
      create(:budget_deposit, budget: budget, amount: 777, date: Date.new(2026, 10, 1))
      create(:budget_deposit, amount: 999, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select "a[href='#{month_deposits_path("2026-09")}']" do
        assert_select ".stat-title", text: "Ready to Assign"
        assert_select ".stat-value", text: "$4,000.00"
        expect(stat_description).to eq("Carried over $1,000.00 · Deposited $3,000.00 · Assigned $0.00")
      end
    end

    it "shows the amounts it's described with the way every amount is shown, so a negative would be signed and red" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select ".stat-desc span", count: 3
      assert_select ".stat-desc span", text: "$0.00", count: 2
      assert_select ".stat-desc span", text: "$3,000.00"
    end

    it "is $0.00 for a budget with no Deposits" do
      get month_path("2026-09")

      assert_select ".stat-value", text: "$0.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $0.00 · Assigned $0.00")
    end

    it "carries forward into a month with no Deposits of its own" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 7, 1))

      get month_path("2026-12")

      assert_select ".stat-value", text: "$3,000.00"
      expect(stat_description).to eq("Carried over $3,000.00 · Deposited $0.00 · Assigned $0.00")
    end

    it "counts a Deposit dated September 30 and marked for October in October, and not in September" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))

      get month_path("2026-09")
      expect(stat_description).to eq("Carried over $0.00 · Deposited $0.00 · Assigned $0.00")

      get month_path("2026-10")
      assert_select ".stat-value", text: "$3,000.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $3,000.00 · Assigned $0.00")
    end

    it "is shown in the budget's currency unit" do
      budget.update!(currency: "GBP")
      create(:budget_deposit, budget: budget, amount: 25, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select ".stat-value", text: "£25.00"
    end
  end

  describe "Assigned" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 25) }
    let!(:rent) { create(:budget_envelope, budget: budget, name: "Rent") }
    let(:january) { Date.new(2026, 1, 1) }
    let(:february) { Date.new(2026, 2, 1) }

    # The worked example: $3,000 is deposited in each of January and February, with $2,800 assigned in January
    # and $3,100 in February.
    def set_up_the_worked_example
      create(:budget_deposit, budget: budget, amount: 3000, date: january)
      create(:budget_deposit, budget: budget, amount: 3000, date: february)
      create(:budget_assignment, envelope: groceries, month: january, amount: 1300)
      create(:budget_assignment, envelope: rent, month: january, amount: 1500)
      create(:budget_assignment, envelope: groceries, month: february, amount: 1600)
      create(:budget_assignment, envelope: rent, month: february, amount: 1500)
    end

    it "shows exactly the numbers of the worked example, in January and then in February" do
      set_up_the_worked_example

      get month_path("2026-01")
      assert_select ".stat-title", text: "Ready to Assign"
      assert_select ".stat-value", text: "$200.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $3,000.00 · Assigned $2,800.00")

      get month_path("2026-02")
      assert_select ".stat-value", text: "$100.00"
      expect(stat_description).to eq("Carried over $200.00 · Deposited $3,000.00 · Assigned $3,100.00")
    end

    it "shows each envelope's Carried over, Assigned and Available, in the month's own columns" do
      set_up_the_worked_example

      get month_path("2026-02")

      assert_select "tr#envelope_#{groceries.id}" do
        assert_select "td:nth-child(2)", text: "$1,325.00"
        assert_select "td:nth-child(4)", text: "$0.00"
        assert_select "td:nth-child(6)", text: "$2,925.00"
      end
      expect(assigned_for(groceries)).to eq("$1,600.00")
      assert_select "tr#envelope_#{rent.id}" do
        assert_select "td:nth-child(2)", text: "$1,500.00"
        assert_select "td:nth-child(4)", text: "$0.00"
        assert_select "td:nth-child(6)", text: "$3,000.00"
      end
      expect(assigned_for(rent)).to eq("$1,500.00")
    end

    it "shows $0.00 for an envelope with nothing assigned in the month" do
      create(:budget_assignment, envelope: rent, month: january, amount: 1500)

      get month_path("2026-02")

      expect(assigned_for(groceries)).to eq("$0.00")
      expect(assigned_for(rent)).to eq("$0.00")
    end

    it "makes each envelope's Assigned a button that opens its input in the cell's own frame, and says which one" do
      get month_path("2026-02")

      assert_select "tbody tr#envelope_#{groceries.id} td:nth-child(3) turbo-frame#assigned_envelope_#{groceries.id}" do
        assert_select "form[method=get][action='#{edit_month_envelope_assignment_path("2026-02", groceries)}'] button.btn" do
          assert_select "span.sr-only", text: "Assigned to Groceries in February 2026:"
        end
      end
      assert_select "tbody tr#envelope_#{rent.id} td:nth-child(3) turbo-frame#assigned_envelope_#{rent.id}"
    end

    it "tell the input which page it was opened from: the home page, at /, and the month view at its own address" do
      travel_to Time.utc(2026, 9, 15, 16)

      get root_path
      assert_select "tbody form[method=get] input[type=hidden][name=from][value=home]", count: 2
      assert_select "tbody form[method=get] input[name=from][value=month]", count: 0

      get month_path("2026-09")
      assert_select "tbody form[method=get] input[type=hidden][name=from][value=month]", count: 2
      assert_select "tbody form[method=get] input[name=from][value=home]", count: 0

      get month_path("2026-08")
      assert_select "tbody form[method=get] input[type=hidden][name=from][value=month]", count: 2
    end

    it "keeps Assigned, Spent and Available on a phone, where only Carried over and Refunded are dropped" do
      get month_path("2026-02")

      assert_select "thead th", text: "Assigned"
      [ 3, 4, 6 ].each do |column|
        assert_select "thead th:nth-child(#{column})[class~='hidden']", count: 0
        assert_select "tbody td:nth-child(#{column})[class~='hidden']", count: 0
      end
      [ 2, 5 ].each do |column|
        assert_select "thead th:nth-child(#{column})[class~='hidden'][class~='sm:table-cell']", count: 1
        assert_select "tbody td:nth-child(#{column})[class~='hidden'][class~='sm:table-cell']", count: 2
      end
    end

    it "shows what changes in every later month when an earlier month's Assigned is changed" do
      set_up_the_worked_example
      Budget::Assignment.find_by!(envelope: groceries, month: january).update!(amount: 1450)

      get month_path("2026-01")
      assert_select ".stat-value", text: "$50.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $3,000.00 · Assigned $2,950.00")

      get month_path("2026-02")
      assert_select ".stat-value .text-error", text: "-$50.00"
      expect(stat_description).to eq("Carried over $50.00 · Deposited $3,000.00 · Assigned $3,100.00")
      assert_select "tr#envelope_#{groceries.id} td:nth-child(2)", text: "$1,475.00"
      assert_select "tr#envelope_#{groceries.id} td:nth-child(6)", text: "$3,075.00"
      expect(assigned_for(groceries)).to eq("$1,600.00")
    end

    it "lowers Ready to Assign only from the month an Assigned amount is for" do
      create(:budget_deposit, budget: budget, amount: 1000, date: january)
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 3, 1), amount: 300)

      [ [ "2026-01", "$1,000.00" ], [ "2026-02", "$1,000.00" ], [ "2026-03", "$700.00" ] ].each do |month, ready_to_assign|
        get month_path(month)

        assert_select ".stat-value", text: ready_to_assign
      end
    end

    it "takes a Deposit marked for next month out of next month's Ready to Assign, not the month of its date" do
      create(:budget_deposit, budget: budget, amount: 1500, date: Date.new(2026, 9, 15), month: Date.new(2026, 10, 1))
      create(:budget_deposit, budget: budget, amount: 1500, date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 10, 1), amount: 3000)

      get month_path("2026-09")
      assert_select ".stat-value", text: "$0.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $0.00 · Assigned $0.00")

      get month_path("2026-10")
      assert_select ".stat-value", text: "$0.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $3,000.00 · Assigned $3,000.00")
    end

    it "doesn't count another budget's Assigned amounts" do
      create(:budget_assignment, month: january, amount: 999)

      get month_path("2026-01")

      expect(stat_description).to eq("Carried over $0.00 · Deposited $0.00 · Assigned $0.00")
    end

    it "is in the budget's currency unit" do
      budget.update!(currency: "GBP")
      create(:budget_assignment, envelope: groceries, month: january, amount: 25)

      get month_path("2026-01")

      expect(assigned_for(groceries)).to eq("£25.00")
    end
  end

  describe "Spent" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
    let!(:rent) { create(:budget_envelope, budget: budget, name: "Rent") }

    # What the Spent column shows for an envelope.
    def spent_for(envelope)
      css_select("tr#envelope_#{envelope.id} td:nth-child(4)").map { |cell| cell.text.squish }.sole
    end

    # What the Available column shows for an envelope.
    def available_for(envelope)
      css_select("tr#envelope_#{envelope.id} td:nth-child(6)").map { |cell| cell.text.squish }.sole
    end

    # The Groceries worked example: $400 is assigned in each of January to March, and $350, $480 and $300 are spent.
    def set_up_the_groceries_example
      [ "2026-01-01", "2026-02-01", "2026-03-01" ].each do |month|
        create(:budget_assignment, envelope: groceries, month: month, amount: 400)
      end
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 1, 20), amount: 350)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 2, 14), amount: 480)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 3, 3), amount: 300)
    end

    it "shows exactly the numbers of the Groceries example in January, February and March, with February Overspent" do
      set_up_the_groceries_example

      shown = [ "2026-01", "2026-02", "2026-03" ].map do |month|
        get month_path(month)

        cells = css_select("tr#envelope_#{groceries.id} td").map { |cell| cell.text.squish }
        [ cells[1], assigned_for(groceries), cells[3], cells[5] ]
      end

      expect(shown).to eq([
        [ "$0.00", "$400.00", "$350.00", "$50.00" ],
        [ "$50.00", "$400.00", "$480.00", "-$30.00 Overspent" ],
        [ "-$30.00", "$400.00", "$300.00", "$70.00" ]
      ])
    end

    it "marks only February Overspent in the Groceries example" do
      set_up_the_groceries_example

      [ [ "2026-01", 0 ], [ "2026-02", 1 ], [ "2026-03", 0 ] ].each do |month, badges|
        get month_path(month)

        assert_select ".badge", text: "Overspent", count: badges
      end
      get month_path("2026-02")
      assert_select "tr#envelope_#{groceries.id} td:nth-child(6) .badge", text: "Overspent"
      assert_select "tr#envelope_#{groceries.id} td:nth-child(6) .text-error", text: "-$30.00"
    end

    it "shifts every month's Available by a Starting balance: with $25 it's $75, -$5 and $95, and February is still Overspent" do
      set_up_the_groceries_example
      groceries.update!(starting_balance: 25)

      shown = [ "2026-01", "2026-02", "2026-03" ].map do |month|
        get month_path(month)
        available_for(groceries)
      end

      expect(shown).to eq([ "$75.00", "-$5.00 Overspent", "$95.00" ])
    end

    it "carries the balance through a month with no records, with $0.00 Spent" do
      set_up_the_groceries_example

      get month_path("2026-05")

      expect(spent_for(groceries)).to eq("$0.00")
      assert_select "tr#envelope_#{groceries.id} td:nth-child(2)", text: "$70.00"
      expect(available_for(groceries)).to eq("$70.00")
    end

    it "shows $0.00 for an envelope with nothing spent in the month" do
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 8, 31), amount: 10)

      get month_path("2026-09")

      expect(spent_for(groceries)).to eq("$0.00")
      expect(spent_for(rent)).to eq("$0.00")
    end

    it "counts only the Spends dated in the month, each in its own envelope's row" do
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 1), amount: 10)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 30), amount: 5.5)
      create(:budget_spend, envelope: rent, date: Date.new(2026, 9, 15), amount: 1500)
      create(:budget_spend, envelope: rent, date: Date.new(2026, 10, 1), amount: 999)

      get month_path("2026-09")

      expect(spent_for(groceries)).to eq("$15.50")
      expect(spent_for(rent)).to eq("$1,500.00")
    end

    it "doesn't change Ready to Assign" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 1))
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 400)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 10), amount: 350)

      get month_path("2026-09")

      assert_select ".stat-value", text: "$2,600.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $3,000.00 · Assigned $400.00")
    end

    it "doesn't count another budget's Spends" do
      create(:budget_spend, envelope: create(:budget_envelope), date: Date.new(2026, 9, 10), amount: 999)

      get month_path("2026-09")

      expect(spent_for(groceries)).to eq("$0.00")
    end

    it "is in the budget's currency unit" do
      budget.update!(currency: "GBP")
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 10), amount: 25)

      get month_path("2026-09")

      expect(spent_for(groceries)).to eq("£25.00")
    end
  end

  describe "a negative Ready to Assign" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

    before do
      create(:budget_deposit, budget: budget, amount: 100, date: Date.new(2026, 9, 1))
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 250)
    end

    it "is shown with its sign and in red, and the card says in words that more was assigned than deposited" do
      get month_path("2026-09")

      assert_select ".stat-value .text-error", text: "-$150.00"
      assert_select ".stat-desc.text-error", text: "More was assigned than deposited."
      expect(stat_description).to eq("Carried over $0.00 · Deposited $100.00 · Assigned $250.00")
    end

    it "is reported in the month it's opened in, and also in the months after it, which it carries into" do
      get month_path("2026-10")

      assert_select ".stat-value .text-error", text: "-$150.00"
      assert_select ".stat-desc.text-error", text: "More was assigned than deposited."
      expect(stat_description).to eq("Carried over -$150.00 · Deposited $0.00 · Assigned $0.00")
    end

    it "isn't reported in a month before the money was assigned" do
      get month_path("2026-08")

      assert_select ".stat-desc.text-error", count: 0
      assert_select ".stat-value .text-error", count: 0
    end

    it "isn't reported when everything deposited has been assigned, to the cent" do
      create(:budget_deposit, budget: budget, amount: 150, date: Date.new(2026, 9, 2))

      get month_path("2026-09")

      assert_select ".stat-value", text: "$0.00"
      assert_select ".stat-desc.text-error", count: 0
      assert_select ".stat-value .text-error", count: 0
    end

    it "isn't reported for a positive amount" do
      create(:budget_deposit, budget: budget, amount: 1000, date: Date.new(2026, 9, 2))

      get month_path("2026-09")

      assert_select ".stat-value", text: "$850.00"
      assert_select ".stat-desc.text-error", count: 0
    end
  end

  describe "refreshing in place" do
    it "asks Turbo to morph the month view and keep the scroll position when it's refreshed, so saving Assigned stays put" do
      get month_path("2026-09")

      assert_select "head meta[name=turbo-refresh-method][content=morph]"
      assert_select "head meta[name=turbo-refresh-scroll][content=preserve]"
    end

    it "says nothing of the kind on the pages that aren't refreshed in place" do
      envelope = create(:budget_envelope, budget: budget)

      [ month_deposits_path("2026-09"), month_envelope_path("2026-09", envelope), new_envelope_path ].each do |path|
        get path

        assert_select "head meta[name=turbo-refresh-method]", count: 0
        assert_select "head meta[name=turbo-refresh-scroll]", count: 0
      end
    end
  end

  describe "setting Assigned from the month view" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 25) }
    let(:frame) { "assigned_envelope_#{groceries.id}" }

    before do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 1, 1))
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 2, 1))
    end

    it "goes back to the month that was edited, and the months after it follow from what was set" do
      get month_path("2026-01")
      assert_select ".stat-value", text: "$3,000.00"
      expect(assigned_for(groceries)).to eq("$0.00")

      # Tap Assigned in the Groceries row: its button loads the input into the cell's frame.
      edit_path = css_select("tr#envelope_#{groceries.id} form[method=get]").first["action"]
      get edit_path, headers: { "Turbo-Frame" => frame }
      form = css_select("turbo-frame##{frame} form").first
      expect(form["action"]).to eq(month_envelope_assignment_path("2026-01", groceries))

      # Save 2,800 for January: the redirect is to January, and January shows it.
      patch form["action"], params: { assignment: { amount: "2800" } }
      expect(response).to redirect_to(month_path("2026-01"))
      follow_redirect!
      assert_select "h1", text: "January 2026"
      assert_select ".stat-value", text: "$200.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $3,000.00 · Assigned $2,800.00")
      expect(assigned_for(groceries)).to eq("$2,800.00")

      # February carries what's left over from January, and what was assigned in January.
      get month_path("2026-02")
      assert_select ".stat-value", text: "$3,200.00"
      expect(stat_description).to eq("Carried over $200.00 · Deposited $3,000.00 · Assigned $0.00")
      assert_select "tr#envelope_#{groceries.id} td:nth-child(2)", text: "$2,825.00"
      expect(assigned_for(groceries)).to eq("$0.00")
    end

    it "changes a past month from its own month view, and only that month's Assigned" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 1, 1), amount: 1000)
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 2, 1), amount: 2000)

      patch month_envelope_assignment_path("2026-01", groceries), params: { assignment: { amount: "1150" } }
      expect(response).to redirect_to(month_path("2026-01"))

      get month_path("2026-02")
      expect(assigned_for(groceries)).to eq("$2,000.00")
      assert_select "tr#envelope_#{groceries.id} td:nth-child(2)", text: "$1,175.00"
      expect(stat_description).to eq("Carried over $1,850.00 · Deposited $3,000.00 · Assigned $2,000.00")
    end

    it "clears what was assigned, so the month shows $0.00 again" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 1, 1), amount: 1000)

      patch month_envelope_assignment_path("2026-01", groceries), params: { assignment: { amount: "" } }
      follow_redirect!

      expect(assigned_for(groceries)).to eq("$0.00")
      assert_select ".stat-value", text: "$3,000.00"
    end
  end

  describe "the header" do
    it "links Budgie to the home page and shows the budget's currency once" do
      get month_path("2026-09")

      assert_select "header a[href='/']", text: "Budgie"
      assert_select "header", text: /Budget in CAD/
      expect(response.body.scan("CAD").size).to eq(1)
    end

    it "keeps only Sign out in the main navigation" do
      create(:budget_envelope, budget: budget)

      get month_path("2026-09")

      assert_select "nav[aria-label=Main] form[action='#{session_path}'] button", text: "Sign out"
      assert_select "nav[aria-label=Main] a", count: 0
    end
  end

  describe "Refunded" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
    let!(:rent) { create(:budget_envelope, budget: budget, name: "Rent") }

    # What the Refunded column shows for an envelope.
    def refunded_for(envelope)
      css_select("tr#envelope_#{envelope.id} td:nth-child(5)").map { |cell| cell.text.squish }.sole
    end

    # What the Available column shows for an envelope.
    def available_for(envelope)
      css_select("tr#envelope_#{envelope.id} td:nth-child(6)").map { |cell| cell.text.squish }.sole
    end

    # The Groceries worked example, with a $50 Refund in February: $400 is assigned in each of January to March, and $350,
    # $480 and $300 are spent.
    def set_up_the_groceries_example
      [ "2026-01-01", "2026-02-01", "2026-03-01" ].each do |month|
        create(:budget_assignment, envelope: groceries, month: month, amount: 400)
      end
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 1, 20), amount: 350)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 2, 14), amount: 480)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 3, 3), amount: 300)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 2, 20), amount: 50)
    end

    it "shows all five figures of an envelope from sm: up, in order: Carried over, Assigned, Spent, Refunded and Available" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 400)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 10), amount: 100)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 9, 11), amount: 25.5)

      get month_path("2026-09")

      expect(css_select("thead th").map { |heading| heading.text.squish }).to eq([ "Envelope", "Carried over", "Assigned", "Spent", "Refunded", "Available" ])
      cells = css_select("tr#envelope_#{groceries.id} td").map { |cell| cell.text.squish }
      expect([ cells[0], cells[1], assigned_for(groceries), *cells[3..] ]).to eq([ "Groceries", "$0.00", "$400.00", "$100.00", "$25.50", "$325.50" ])
    end

    it "shows exactly the numbers of the Groceries example with a $50 Refund in February: Available $50, $20 and $120, with none Overspent" do
      set_up_the_groceries_example

      shown = [ "2026-01", "2026-02", "2026-03" ].map do |month|
        get month_path(month)
        [ refunded_for(groceries), available_for(groceries), css_select(".badge").size ]
      end

      expect(shown).to eq([ [ "$0.00", "$50.00", 0 ], [ "$50.00", "$20.00", 0 ], [ "$0.00", "$120.00", 0 ] ])
    end

    it "leaves Ready to Assign as it was with the Refund, in every month" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 1, 1))
      set_up_the_groceries_example
      ready_to_assign = lambda do
        [ "2026-01", "2026-02", "2026-03" ].map do |month|
          get month_path(month)
          css_select(".stat").first.text.squish
        end
      end

      with_the_refund = ready_to_assign.call
      Budget::Refund.find_by!(envelope: groceries).destroy!

      expect(with_the_refund).to eq(ready_to_assign.call)
    end

    it "shows $0.00 for an envelope with nothing refunded in the month" do
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 8, 31), amount: 10)

      get month_path("2026-09")

      expect(refunded_for(groceries)).to eq("$0.00")
      expect(refunded_for(rent)).to eq("$0.00")
    end

    it "counts only the Refunds dated in the month, each in its own envelope's row" do
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 9, 1), amount: 10)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 9, 30), amount: 5.5)
      create(:budget_refund, envelope: rent, date: Date.new(2026, 9, 15), amount: 1500)
      create(:budget_refund, envelope: rent, date: Date.new(2026, 10, 1), amount: 999)

      get month_path("2026-09")

      expect(refunded_for(groceries)).to eq("$15.50")
      expect(refunded_for(rent)).to eq("$1,500.00")
    end

    it "doesn't count another budget's Refunds" do
      create(:budget_refund, envelope: create(:budget_envelope), date: Date.new(2026, 9, 10), amount: 999)

      get month_path("2026-09")

      expect(refunded_for(groceries)).to eq("$0.00")
    end

    it "is in the budget's currency unit" do
      budget.update!(currency: "GBP")
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 9, 10), amount: 25)

      get month_path("2026-09")

      expect(refunded_for(groceries)).to eq("£25.00")
    end
  end

  describe "the envelopes" do
    it "are listed alphabetically, each name linking to its page, with Carried over, Assigned, Spent, Refunded and Available" do
      rent = create(:budget_envelope, budget: budget, name: "rent", starting_balance: 1234.5)
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: 40)
      create(:budget_envelope, name: "Someone else's", starting_balance: 5)

      get month_path("2026-09")

      assert_select "thead th", text: "Envelope"
      assert_select "thead th", text: "Carried over"
      assert_select "thead th", text: "Assigned"
      assert_select "thead th", text: "Spent"
      assert_select "thead th", text: "Refunded"
      assert_select "thead th", text: "Available"
      assert_select "thead th:nth-child(2)", text: "Carried over"
      assert_select "thead th:nth-child(3)", text: "Assigned"
      assert_select "thead th:nth-child(4)", text: "Spent"
      assert_select "thead th:nth-child(5)", text: "Refunded"
      assert_select "thead th:nth-child(6)", text: "Available"
      assert_select "tbody tr", count: 2
      assert_select "tbody tr:nth-child(1) td:nth-child(1) a[href='#{month_envelope_path("2026-09", bills)}']", text: "Bills"
      assert_select "tbody tr:nth-child(1) td:nth-child(2)", text: "$40.00"
      assert_select "tbody tr:nth-child(1) td:nth-child(4)", text: "$0.00"
      assert_select "tbody tr:nth-child(1) td:nth-child(5)", text: "$0.00"
      assert_select "tbody tr:nth-child(1) td:nth-child(6)", text: "$40.00"
      assert_select "tbody tr:nth-child(2) td:nth-child(1) a[href='#{month_envelope_path("2026-09", rent)}']", text: "rent"
      assert_select "tbody tr:nth-child(2) td:nth-child(6)", text: "$1,234.50"
      expect(response.body).not_to include("Someone else")
    end

    it "show their Starting balance as Available in every month, and say Overspent when it's negative" do
      create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      create(:budget_envelope, budget: budget, name: "Fuel", starting_balance: 0)

      [ "2026-09", "2024-01", "2031-12" ].each do |month|
        get month_path(month)

        assert_select "tbody tr:nth-child(1) td:nth-child(6)", text: /\A-\$30\.00\s+Overspent\z/
        assert_select "tbody tr:nth-child(1) td:nth-child(6) .text-error", text: "-$30.00"
        assert_select "tbody tr:nth-child(2) td:nth-child(6)", text: "$0.00"
        assert_select ".badge", text: "Overspent", count: 1
      end
    end

    it "right-align their amounts, and drop Carried over and Refunded on a phone, which keeps Assigned, Spent and Available" do
      create(:budget_envelope, budget: budget)

      get month_path("2026-09")

      assert_select "thead th[scope=col].text-right", text: "Assigned"
      assert_select "thead th[scope=col].text-right", text: "Spent"
      assert_select "thead th[scope=col].text-right", text: "Refunded"
      assert_select "thead th[scope=col].text-right", text: "Available"
      assert_select "thead th[class~='hidden'][class~='sm:table-cell']", text: "Carried over"
      assert_select "thead th[class~='hidden'][class~='sm:table-cell']", text: "Refunded"
      assert_select "thead th[class~='hidden']", count: 2
      assert_select "tbody td.text-right.tabular-nums", count: 5
      assert_select "tbody td[class~='hidden'][class~='sm:table-cell']", count: 2
    end

    it "are replaced by an invitation to create one when there are none" do
      get month_path("2026-09")

      assert_select "table", count: 0
      assert_select "main p", text: "You don't have any envelopes yet."
      assert_select ".border-dashed a[href='#{new_envelope_path(month: "2026-09", from: "month")}']", text: "New envelope"
    end
  end

  describe "the actions" do
    it "are New spend, the main one, then New deposit and New envelope, each remembering the month and page they were opened from" do
      get month_path("2026-09")

      assert_select "a.btn.btn-primary[href='#{new_spend_path(month: "2026-09", from: "month")}']", text: "New spend"
      assert_select "div.gap-2 a.btn-primary", count: 1
      expect(css_select("div.gap-2 a.btn").map { |action| action.text.strip }).to eq([ "New spend", "New deposit", "New envelope" ])
      assert_select "a.btn[href='#{new_deposit_path(month: "2026-09", from: "month")}']", text: "New deposit"
      assert_select "a.btn[href='#{new_envelope_path(month: "2026-09", from: "month")}']", text: "New envelope"
    end

    it "have no New refund: Refunds are added from an envelope's page" do
      create(:budget_envelope, budget: budget)

      get month_path("2026-09")

      assert_select "a[href^='#{new_refund_path}']", count: 0
      expect(response.body).not_to include("New refund")
    end
  end

  describe "the month links" do
    before { travel_to Time.utc(2026, 9, 15, 16) }

    it "go to the months either side, and stay on the month view" do
      get month_path("2026-09")

      assert_select "nav[aria-label=Months] a[href='#{month_path("2026-08")}']", text: "August 2026"
      assert_select "nav[aria-label=Months] a[href='#{month_path("2026-10")}']", text: "October 2026"
    end

    it "offer This month only when viewing another month" do
      get month_path("2026-09")
      assert_select "a", text: "This month", count: 0

      get month_path("2027-03")
      assert_select "a[href='#{month_path("2026-09")}']", text: "This month"
    end

    it "work in both directions, however far from today" do
      get month_path("1990-01")
      assert_select "a[href='#{month_path("1989-12")}']", text: "December 1989"

      get month_path("2100-12")
      assert_select "a[href='#{month_path("2101-01")}']", text: "January 2101"
    end
  end
end
