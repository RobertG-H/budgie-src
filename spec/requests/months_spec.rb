require "rails_helper"

RSpec.describe "Months", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }

  before { sign_in_as budget.user }

  # The labelled figures under Ready to Assign's number, as "Carried over $0.00 · Deposited $0.00 · Assigned $0.00". Each
  # is a label over an amount in a span of its own, so the whitespace between the pieces is collapsed before comparing.
  def stat_description
    css_select("#ready-to-assign dl > div").map { |figure| figure.text.squish }.join(" · ")
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
      assert_select "nav[aria-label=Months] a[rel=next]", text: /January 10000/

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
    it "is every Deposit for the month and before it, with what was carried over and deposited, and a link to the month's Deposits" do
      create(:budget_deposit, budget: budget, amount: 1000, date: Date.new(2026, 8, 1))
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 1))
      create(:budget_deposit, budget: budget, amount: 777, date: Date.new(2026, 10, 1))
      create(:budget_deposit, amount: 999, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select "#ready-to-assign" do
        assert_select ".stat-title", text: "Ready to Assign"
        assert_select ".stat-value", text: "$4,000.00"
        expect(stat_description).to eq("Carried over $1,000.00 · Deposited $3,000.00 · Assigned $0.00")
        assert_select "a[href='#{month_deposits_path("2026-09")}']", text: "See Deposits", count: 1
      end
    end

    it "shows the amounts it's described with the way every amount is shown, so a negative would be signed and red" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select "#ready-to-assign dd span", count: 3
      assert_select "#ready-to-assign dd span", text: "$0.00", count: 2
      assert_select "#ready-to-assign dd span", text: "$3,000.00"
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
        assert_select "td:nth-child(7)", text: "$2,925.00"
      end
      expect(assigned_for(groceries)).to eq("$1,600.00")
      assert_select "tr#envelope_#{rent.id}" do
        assert_select "td:nth-child(2)", text: "$1,500.00"
        assert_select "td:nth-child(4)", text: "$0.00"
        assert_select "td:nth-child(7)", text: "$3,000.00"
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

    it "keeps Assigned, Spent and Available on a phone, where only Carried over, Refunded and Reallocated are dropped" do
      get month_path("2026-02")

      assert_select "thead th", text: "Assigned"
      [ 3, 4, 7 ].each do |column|
        assert_select "thead th:nth-child(#{column})[class~='hidden']", count: 0
        assert_select "tbody tr[id] td:nth-child(#{column})[class~='hidden']", count: 0
      end
      [ 2, 5, 6 ].each do |column|
        assert_select "thead th:nth-child(#{column})[class~='hidden'][class~='sm:in-data-[details=on]:table-cell']", count: 1
        assert_select "tbody tr[id] td:nth-child(#{column})[class~='hidden'][class~='sm:in-data-[details=on]:table-cell']", count: 2
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
      assert_select "tr#envelope_#{groceries.id} td:nth-child(7)", text: "$3,075.00"
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
      css_select("tr#envelope_#{envelope.id} td:nth-child(7)").map { |cell| cell.text.squish }.sole
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
        [ cells[1], assigned_for(groceries), cells[3], cells[6] ]
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
      assert_select "tr#envelope_#{groceries.id} td:nth-child(7) .badge", text: "Overspent"
      assert_select "tr#envelope_#{groceries.id} td:nth-child(7) .text-error", text: "-$30.00"
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

  describe "Ready to Assign with Reallocations to it" do
    let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }

    before do
      create(:budget_deposit, budget: budget, amount: 600, date: Date.new(2026, 2, 1))
      create(:budget_assignment, envelope: dining_out, month: Date.new(2026, 2, 1), amount: 600)
      create(:budget_ready_to_assign_reallocation, envelope: dining_out, amount: 30, date: Date.new(2026, 2, 20))
    end

    it "adds Reallocated after Assigned in the month it's dated in, so the arithmetic on the card adds up" do
      get month_path("2026-02")

      assert_select ".stat-value", text: "$30.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $600.00 · Assigned $600.00 · Reallocated $30.00")
    end

    it "shows the amount the way every amount is shown, in a span of its own" do
      get month_path("2026-02")

      assert_select "#ready-to-assign dd span", count: 4
      assert_select "#ready-to-assign dd span", text: "$30.00"
    end

    it "carries it into the months after, which show no Reallocated of their own" do
      get month_path("2026-03")

      assert_select ".stat-value", text: "$30.00"
      expect(stat_description).to eq("Carried over $30.00 · Deposited $0.00 · Assigned $0.00")
    end

    it "shows no Reallocated in a month before it, or in a budget that has none" do
      get month_path("2026-01")
      expect(stat_description).to eq("Carried over $0.00 · Deposited $0.00 · Assigned $0.00")

      Budget::ReadyToAssignReallocation.delete_all
      get month_path("2026-02")
      expect(stat_description).to eq("Carried over $0.00 · Deposited $600.00 · Assigned $600.00")
      expect(response.body).not_to include("Reallocated $")
    end

    it "shows nothing for a Reallocation to Ready to Assign in another budget" do
      Budget::ReadyToAssignReallocation.delete_all
      create(:budget_ready_to_assign_reallocation, amount: 999, date: Date.new(2026, 2, 20))

      get month_path("2026-02")

      expect(stat_description).to eq("Carried over $0.00 · Deposited $600.00 · Assigned $600.00")
    end

    it "is in the Reallocated column of its envelope, as money out, and in Available" do
      get month_path("2026-02")

      expect(css_select("tr#envelope_#{dining_out.id} td:nth-child(6)").map { |cell| cell.text.squish }).to eq([ "-$30.00" ])
      assert_select "tr#envelope_#{dining_out.id} td:nth-child(6) .text-error", text: "-$30.00"
      expect(css_select("tr#envelope_#{dining_out.id} td:nth-child(7)").map { |cell| cell.text.squish }).to eq([ "$570.00" ])
    end

    it "can bring a negative Ready to Assign back to zero" do
      create(:budget_assignment, envelope: dining_out, month: Date.new(2026, 3, 1), amount: 30)

      get month_path("2026-03")
      assert_select ".stat-value", text: "$0.00"
      assert_select "#ready-to-assign", text: /More was assigned/, count: 0
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
      assert_select "#ready-to-assign .text-error", text: "More was assigned than deposited."
      expect(stat_description).to eq("Carried over $0.00 · Deposited $100.00 · Assigned $250.00")
    end

    it "is reported in the month it's opened in, and also in the months after it, which it carries into" do
      get month_path("2026-10")

      assert_select ".stat-value .text-error", text: "-$150.00"
      assert_select "#ready-to-assign .text-error", text: "More was assigned than deposited."
      expect(stat_description).to eq("Carried over -$150.00 · Deposited $0.00 · Assigned $0.00")
    end

    it "isn't reported in a month before the money was assigned" do
      get month_path("2026-08")

      assert_select "#ready-to-assign .text-error", count: 0
    end

    it "isn't reported when everything deposited has been assigned, to the cent" do
      create(:budget_deposit, budget: budget, amount: 150, date: Date.new(2026, 9, 2))

      get month_path("2026-09")

      assert_select ".stat-value", text: "$0.00"
      assert_select "#ready-to-assign .text-error", count: 0
    end

    it "isn't reported for a positive amount" do
      create(:budget_deposit, budget: budget, amount: 1000, date: Date.new(2026, 9, 2))

      get month_path("2026-09")

      assert_select ".stat-value", text: "$850.00"
      assert_select "#ready-to-assign .text-error", count: 0
    end
  end

  # The card says in words whether there's money left to assign, and only the current month gets the loud warning styling.
  describe "the Ready to Assign card's states" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

    # September 2026 is the current month, in Eastern time.
    before { travel_to Time.utc(2026, 9, 15, 16) }

    def deposit(amount, date) = create(:budget_deposit, budget: budget, amount: amount, date: date)
    def assign(amount, month) = create(:budget_assignment, envelope: groceries, month: month, amount: amount)

    describe "with money left to assign" do
      before do
        deposit 3000, Date.new(2026, 9, 1)
        assign 2800, Date.new(2026, 9, 1)
      end

      it "says 'left to assign' in a warning badge, on a warning card, in the current month" do
        get month_path("2026-09")

        assert_select "section#ready-to-assign.border-warning.bg-warning\\/10" do
          assert_select ".stat-value", text: "$200.00"
          assert_select ".badge.badge-warning", text: "left to assign"
        end
      end

      it "is the same on the home page, which is the current month too" do
        get root_path

        assert_select "section#ready-to-assign.border-warning", count: 1
        assert_select "#ready-to-assign .badge-warning", text: "left to assign"
      end

      it "says it quietly in a ghost badge, with no warning, in a month that isn't the current one" do
        get month_path("2026-10")

        assert_select "#ready-to-assign .stat-value", text: "$200.00"
        assert_select "#ready-to-assign .badge.badge-ghost", text: "left to assign"
        assert_select "#ready-to-assign .badge-warning", count: 0
        assert_select "section#ready-to-assign.border-base-300"
        assert_select "section#ready-to-assign.border-warning", count: 0
        assert_select "section#ready-to-assign.bg-warning\\/10", count: 0

        get month_path("2026-08")
        assert_select "#ready-to-assign .badge-warning", count: 0
      end

      it "never uses the warning colour as text" do
        get month_path("2026-09")

        assert_select "#ready-to-assign .text-warning", count: 0
      end
    end

    describe "with everything assigned" do
      before do
        deposit 3000, Date.new(2026, 9, 1)
        assign 3000, Date.new(2026, 9, 1)
      end

      it "says 'All assigned' in a success badge on a plain card" do
        get month_path("2026-09")

        assert_select "section#ready-to-assign.border-base-300" do
          assert_select ".stat-value", text: "$0.00"
          assert_select ".badge.badge-success", text: "All assigned"
        end
        assert_select "#ready-to-assign .badge-warning", count: 0
        assert_select "section#ready-to-assign.border-warning", count: 0
      end

      it "is the same in a month that isn't the current one, since a plain card has nothing to tone down" do
        deposit 3000, Date.new(2026, 10, 1)
        assign 3000, Date.new(2026, 10, 1)

        get month_path("2026-10")

        assert_select "#ready-to-assign .badge.badge-success", text: "All assigned"
        assert_select "#ready-to-assign .stat-value", text: "$0.00"
      end

      it "gives way to 'nothing yet' in a later month where nothing at all is carried or entered" do
        get month_path("2026-12")

        assert_select "#ready-to-assign .badge-success", count: 0
        assert_select "#ready-to-assign span", text: "Nothing to assign yet."
      end
    end

    describe "with more assigned than deposited" do
      before do
        deposit 100, Date.new(2026, 9, 1)
        assign 250, Date.new(2026, 9, 1)
      end

      it "has an error border and says so in the error colour, in the current month" do
        get month_path("2026-09")

        assert_select "section#ready-to-assign.border-error" do
          assert_select ".stat-value .text-error", text: "-$150.00"
          assert_select ".text-error", text: "More was assigned than deposited."
        end
        assert_select "section#ready-to-assign.border-warning", count: 0
        assert_select "#ready-to-assign .badge", count: 0
      end

      it "is error-styled in a later month that carries it, and in a future month that only holds Assigned entered ahead" do
        get month_path("2026-10")
        assert_select "section#ready-to-assign.border-error"
        assert_select "#ready-to-assign .text-error", text: "More was assigned than deposited."

        Budget::Deposit.delete_all
        Budget::Assignment.delete_all
        assign 40, Date.new(2026, 11, 1)
        get month_path("2026-11")
        assert_select "section#ready-to-assign.border-error"
        assert_select "#ready-to-assign .text-error", text: "More was assigned than deposited."
      end

      it "is over-assigned in a month with no Deposit of its own, however little" do
        Budget::Deposit.delete_all
        Budget::Assignment.delete_all
        assign "0.01", Date.new(2026, 9, 1)

        get month_path("2026-09")

        assert_select "section#ready-to-assign.border-error"
        assert_select "#ready-to-assign .stat-value .text-error", text: "-$0.01"
      end
    end

    describe "with nothing yet" do
      before { Budget::Envelope.delete_all }

      it "is a new budget's card: muted words and a New deposit button, and never the warning" do
        get root_path

        assert_select "section#ready-to-assign.border-base-300" do
          assert_select ".stat-value", text: "$0.00"
          assert_select "span", text: "Nothing to assign yet."
          assert_select "a.btn.btn-sm[href='#{new_deposit_path(month: "2026-09", from: "month")}']", text: "New deposit"
        end
        assert_select "section#ready-to-assign.border-warning", count: 0
        assert_select "#ready-to-assign .badge", count: 0
        assert_select "#ready-to-assign .text-error", count: 0
      end

      it "is the same for any month nothing has happened in" do
        get month_path("2028-01")

        assert_select "#ready-to-assign span", text: "Nothing to assign yet."
        assert_select "#ready-to-assign a", text: "New deposit"
      end

      it "goes away as soon as a Deposit lands in the month, or before it" do
        deposit 10, Date.new(2026, 8, 1)

        get month_path("2026-09")

        assert_select "#ready-to-assign span", text: "Nothing to assign yet.", count: 0
        assert_select "#ready-to-assign a", text: "New deposit", count: 0
        assert_select "#ready-to-assign .badge-warning", text: "left to assign"
      end
    end

    describe "the card" do
      it "isn't a link, and the way to the month's Deposits is a plain link inside it" do
        deposit 3000, Date.new(2026, 9, 1)

        get month_path("2026-09")

        expect(css_select("a #ready-to-assign, a section#ready-to-assign")).to be_empty
        expect(css_select("#ready-to-assign a").map { |link| [ link.text.squish, link["href"] ] })
          .to eq([ [ "See Deposits", month_deposits_path("2026-09") ] ])
        expect(css_select("#ready-to-assign a .stat-value, #ready-to-assign a dl")).to be_empty
      end

      it "labels its figures, and Reallocated is among them only when it isn't zero" do
        deposit 600, Date.new(2026, 9, 1)

        get month_path("2026-09")
        expect(css_select("#ready-to-assign dt").map { |label| label.text.squish }).to eq([ "Carried over", "Deposited", "Assigned" ])

        create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 600)
        create(:budget_ready_to_assign_reallocation, envelope: groceries, amount: 30, date: Date.new(2026, 9, 20))

        get month_path("2026-09")
        expect(css_select("#ready-to-assign dt").map { |label| label.text.squish }).to eq([ "Carried over", "Deposited", "Assigned", "Reallocated" ])
        assert_select "#ready-to-assign .badge-warning", text: "left to assign"
      end
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

    it "keeps only Import and Sign out in the main navigation" do
      create(:budget_envelope, budget: budget)

      get month_path("2026-09")

      assert_select "nav[aria-label=Main] form[action='#{session_path}'] button", text: "Sign out"
      assert_select "nav[aria-label=Main] a", count: 1
      assert_select "nav[aria-label=Main] a[href='#{new_import_path}']", text: "Import"
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
      css_select("tr#envelope_#{envelope.id} td:nth-child(7)").map { |cell| cell.text.squish }.sole
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

    it "shows all six figures of an envelope from sm: up, in order: Carried over, Assigned, Spent, Refunded, Reallocated and Available" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 400)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 10), amount: 100)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 9, 11), amount: 25.5)

      get month_path("2026-09")

      expect(css_select("thead th").map { |heading| heading.text.squish }).to eq([ "Envelope", "Carried over", "Assigned", "Spent", "Refunded", "Reallocated", "Available" ])
      cells = css_select("tr#envelope_#{groceries.id} td").map { |cell| cell.text.squish }
      expect([ cells[0], cells[1], assigned_for(groceries), *cells[3..] ]).to eq([ "Groceries", "$0.00", "$400.00", "$100.00", "$25.50", "$0.00", "$325.50" ])
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

  describe "Reallocated" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
    let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }

    # What the Reallocated column shows for an envelope, which is the sixth.
    def reallocated_for(envelope)
      css_select("tr#envelope_#{envelope.id} td:nth-child(6)").map { |cell| cell.text.squish }.sole
    end

    # What the Available column shows for an envelope.
    def available_for(envelope)
      css_select("tr#envelope_#{envelope.id} td:nth-child(7)").map { |cell| cell.text.squish }.sole
    end

    # The Groceries worked example next to Dining out, which has $200 assigned in each of January to March and nothing
    # spent, and a $30 Reallocation from Dining out to Groceries in February.
    def set_up_the_example
      [ "2026-01-01", "2026-02-01", "2026-03-01" ].each do |month|
        create(:budget_assignment, envelope: groceries, month: month, amount: 400)
        create(:budget_assignment, envelope: dining_out, month: month, amount: 200)
      end
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 1, 20), amount: 350)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 2, 14), amount: 480)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 3, 3), amount: 300)
      create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries, date: Date.new(2026, 2, 20), amount: 30)
    end

    it "shows the Groceries example with a $30 Reallocation in February: Available $50, $0 and $100, with none Overspent" do
      set_up_the_example

      shown = [ "2026-01", "2026-02", "2026-03" ].map do |month|
        get month_path(month)
        [ reallocated_for(groceries), available_for(groceries), reallocated_for(dining_out), available_for(dining_out), css_select(".badge").size ]
      end

      expect(shown).to eq([
        [ "$0.00", "$50.00", "$0.00", "$200.00", 0 ],
        [ "$30.00", "$0.00", "-$30.00", "$370.00", 0 ],
        [ "$0.00", "$100.00", "$0.00", "$570.00", 0 ]
      ])
    end

    it "shows what left an envelope as a negative in red, and what arrived as a positive with no plus sign" do
      set_up_the_example

      get month_path("2026-02")

      assert_select "tr#envelope_#{dining_out.id} td:nth-child(6) .text-error", text: "-$30.00"
      assert_select "tr#envelope_#{groceries.id} td:nth-child(6) .text-error", count: 0
      expect(reallocated_for(groceries)).to eq("$30.00")
    end

    it "is between Refunded and Available, and from sm: up only" do
      set_up_the_example

      get month_path("2026-02")

      expect(css_select("thead th").map { |heading| heading.text.squish }).to eq(
        [ "Envelope", "Carried over", "Assigned", "Spent", "Refunded", "Reallocated", "Available" ]
      )
      assert_select "thead th:nth-child(6)[class~='hidden'][class~='sm:in-data-[details=on]:table-cell'][class~='text-right']", text: "Reallocated"
      assert_select "tbody tr[id] td:nth-child(6)[class~='hidden'][class~='sm:in-data-[details=on]:table-cell'][class~='tabular-nums']", count: 2
    end

    it "has no Reallocate on the month view, and doesn't merge into Assigned" do
      set_up_the_example

      get month_path("2026-02")

      assert_select "a", text: /Reallocate/, count: 0
      expect(assigned_for(groceries)).to eq("$400.00")
      expect(assigned_for(dining_out)).to eq("$200.00")
    end

    it "leaves Ready to Assign as it was with the Reallocation, in every month" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 1, 1))
      set_up_the_example
      ready_to_assign = lambda do
        [ "2026-01", "2026-02", "2026-03" ].map do |month|
          get month_path(month)
          css_select(".stat").first.text.squish
        end
      end

      with_the_reallocation = ready_to_assign.call
      Budget::EnvelopeReallocation.sole.destroy!

      expect(with_the_reallocation).to eq(ready_to_assign.call)
    end

    it "counts only the Reallocations dated in the month, and shows $0.00 for an envelope with none" do
      create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries, date: Date.new(2026, 8, 31), amount: 7)
      create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries, date: Date.new(2026, 9, 30), amount: 5.5)
      create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries, date: Date.new(2026, 10, 1), amount: 999)

      get month_path("2026-09")

      expect(reallocated_for(groceries)).to eq("$5.50")
      expect(reallocated_for(dining_out)).to eq("-$5.50")
    end

    it "doesn't count another budget's Reallocations" do
      create(:budget_envelope_reallocation, date: Date.new(2026, 9, 10), amount: 999)

      get month_path("2026-09")

      expect(reallocated_for(groceries)).to eq("$0.00")
      expect(reallocated_for(dining_out)).to eq("$0.00")
    end

    it "is in the budget's currency unit" do
      budget.update!(currency: "GBP")
      create(:budget_envelope_reallocation, from_envelope: dining_out, to_envelope: groceries, date: Date.new(2026, 9, 10), amount: 25)

      get month_path("2026-09")

      expect(reallocated_for(groceries)).to eq("£25.00")
    end
  end

  describe "the envelopes" do
    it "are listed alphabetically, each name linking to its page, with Carried over, Assigned, Spent, Refunded, Reallocated and Available" do
      rent = create(:budget_envelope, budget: budget, name: "rent", starting_balance: 1234.5)
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: 40)
      create(:budget_envelope, name: "Someone else's", starting_balance: 5)

      get month_path("2026-09")

      assert_select "thead th", text: "Envelope"
      assert_select "thead th", text: "Carried over"
      assert_select "thead th", text: "Assigned"
      assert_select "thead th", text: "Spent"
      assert_select "thead th", text: "Refunded"
      assert_select "thead th", text: "Reallocated"
      assert_select "thead th", text: "Available"
      assert_select "thead th:nth-child(2)", text: "Carried over"
      assert_select "thead th:nth-child(3)", text: "Assigned"
      assert_select "thead th:nth-child(4)", text: "Spent"
      assert_select "thead th:nth-child(5)", text: "Refunded"
      assert_select "thead th:nth-child(6)", text: "Reallocated"
      assert_select "thead th:nth-child(7)", text: "Available"
      assert_select "tbody tr[id]", count: 2
      assert_select "tbody tr[id]:first-child", count: 2
      expect(css_select("tbody tr[id]").map { |row| row["id"] }).to eq([ "envelope_#{bills.id}", "envelope_#{rent.id}" ])
      assert_select "tr#envelope_#{bills.id} td:nth-child(1) a[href='#{month_envelope_path("2026-09", bills)}']", text: "Bills"
      assert_select "tr#envelope_#{bills.id} td:nth-child(2)", text: "$40.00"
      assert_select "tr#envelope_#{bills.id} td:nth-child(4)", text: "$0.00"
      assert_select "tr#envelope_#{bills.id} td:nth-child(5)", text: "$0.00"
      assert_select "tr#envelope_#{bills.id} td:nth-child(6)", text: "$0.00"
      assert_select "tr#envelope_#{bills.id} td:nth-child(7)", text: "$40.00"
      assert_select "tr#envelope_#{rent.id} td:nth-child(1) a[href='#{month_envelope_path("2026-09", rent)}']", text: "rent"
      assert_select "tr#envelope_#{rent.id} td:nth-child(7)", text: "$1,234.50"
      expect(response.body).not_to include("Someone else")
    end

    it "show their Starting balance as Available in every month, and say Overspent when it's negative" do
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      fuel = create(:budget_envelope, budget: budget, name: "Fuel", starting_balance: 0)

      [ "2026-09", "2024-01", "2031-12" ].each do |month|
        get month_path(month)

        assert_select "tr#envelope_#{bills.id} td:nth-child(7)", text: /\A-\$30\.00\s+Overspent\z/
        assert_select "tr#envelope_#{bills.id} td:nth-child(7) .text-error", text: "-$30.00"
        assert_select "tr#envelope_#{fuel.id} td:nth-child(7)", text: "$0.00"
        assert_select ".badge", text: "Overspent", count: 1
      end
    end

    it "right-align their amounts, and drop Carried over, Refunded and Reallocated on a phone, which keeps Assigned, Spent and Available" do
      create(:budget_envelope, budget: budget)

      get month_path("2026-09")

      assert_select "thead th[scope=col].text-right", text: "Assigned"
      assert_select "thead th[scope=col].text-right", text: "Spent"
      assert_select "thead th[scope=col].text-right", text: "Refunded"
      assert_select "thead th[scope=col].text-right", text: "Reallocated"
      assert_select "thead th[scope=col].text-right", text: "Available"
      assert_select "thead th[class~='hidden'][class~='sm:in-data-[details=on]:table-cell']", text: "Carried over"
      assert_select "thead th[class~='hidden'][class~='sm:in-data-[details=on]:table-cell']", text: "Refunded"
      assert_select "thead th[class~='hidden'][class~='sm:in-data-[details=on]:table-cell']", text: "Reallocated"
      assert_select "thead th[class~='hidden']", count: 3
      assert_select "tbody tr[id] td.text-right.tabular-nums", count: 6
      assert_select "tbody tr[id] td[class~='hidden'][class~='sm:in-data-[details=on]:table-cell']", count: 3
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
      assert_select "div.flex.flex-wrap.items-center.gap-2 a.btn-primary", count: 1
      expect(css_select("div.flex.flex-wrap.items-center.gap-2 > a.btn").map { |action| action.text.strip }).to eq([ "New spend", "New deposit", "New envelope" ])
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

      assert_select "nav[aria-label=Months] a[href='#{month_path("2026-08")}']", text: /August 2026/
      assert_select "nav[aria-label=Months] a[href='#{month_path("2026-10")}']", text: /October 2026/
    end

    it "offer This month only when viewing another month" do
      get month_path("2026-09")
      assert_select "nav[aria-label=Months] a", text: "This month", count: 0

      get month_path("2027-03")
      assert_select "nav[aria-label=Months] a[href='#{month_path("2026-09")}']", text: "This month"
    end

    it "work in both directions, however far from today" do
      get month_path("1990-01")
      assert_select "a[href='#{month_path("1989-12")}']", text: /December 1989/

      get month_path("2100-12")
      assert_select "a[href='#{month_path("2101-01")}']", text: /January 2101/
    end

    it "are one control: Previous, the month's name and Next, with the name opening the picker" do
      get month_path("2026-09")

      assert_select "nav[aria-label=Months] .join > a[rel=prev][aria-label='Previous month, August 2026']"
      assert_select "nav[aria-label=Months] .join > a[rel=next][aria-label='Next month, October 2026']"
      assert_select "nav[aria-label=Months] .join > button[hidden][data-month-picker-target=trigger]", text: /September 2026/
    end

    it "stop Previous in January of year 1, and Next is never stopped" do
      get month_path("0001-01")

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "January 0001"
      assert_select "nav[aria-label=Months] a[rel=prev]", count: 0
      assert_select "nav[aria-label=Months] button[disabled][aria-disabled=true]", count: 1
      assert_select "nav[aria-label=Months] a[rel=next][href='#{month_path("0001-02")}']"

      get month_path("0001-02")
      assert_select "nav[aria-label=Months] a[rel=prev][href='#{month_path("0001-01")}']"
    end

    it "render a month as far off as a date field goes" do
      get month_path("275760-09")

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "September 275760"
      assert_select "nav[aria-label=Months] a[rel=next][href='#{month_path("275760-10")}']"
      assert_select "input[type=number][value='275760'][max='275760']"
      assert_select "dialog a[href='#{month_path("275760-09")}'][aria-current=page]"
    end
  end

  describe "the month picker" do
    before { travel_to Time.utc(2026, 9, 15, 16) }

    it "has twelve links to the months of the viewed year, the viewed one marked as the current page, in a dialog" do
      get month_path("2027-03")

      assert_select "dialog.modal[aria-labelledby]", count: 1
      assert_select "dialog h2", text: "Choose a month"
      hrefs = css_select("dialog [role=group] a").map { |link| link["href"] }
      expect(hrefs).to eq((1..12).map { |month| month_path(format("2027-%02d", month)) })
      assert_select "dialog [role=group] a[aria-current=page]", count: 1
      assert_select "dialog [role=group] a[aria-current=page][href='#{month_path("2027-03")}']", text: "Mar"
      assert_select "dialog input[type=number][value='2027'][min='1'][max='275760']"
    end

    it "marks this calendar month in a year that has it, in its name and not only by colour" do
      get month_path("2026-03")

      assert_select "dialog a[href='#{month_path("2026-09")}'][aria-label='September 2026, this month']"
      assert_select "dialog a.btn-outline", count: 1
    end

    it "has a This month button under the grid going to the current month, and a Close button" do
      get month_path("2027-03")

      assert_select "dialog a.btn[href='#{month_path("2026-09")}']", text: "This month"
      assert_select "dialog form[method=dialog] button", text: "Close"
    end

    it "is on the home page too, which is the current month" do
      get root_path

      assert_select "dialog [role=group] a[href='#{month_path("2026-09")}'][aria-current=page]"
    end

    it "is on the month view only: the Deposits page and an envelope's page have the same links and no dialog" do
      envelope = create(:budget_envelope, budget: budget, name: "Groceries")

      [ month_deposits_path("2026-10"), month_envelope_path("2026-10", envelope) ].each do |path|
        get path

        assert_select "nav[aria-label=Months] a[rel=prev]", text: /September 2026/
        assert_select "nav[aria-label=Months] a[rel=next]", text: /November 2026/
        assert_select "nav[aria-label=Months] a", text: "This month"
        assert_select "nav[aria-label=Months] .join > span", text: "October 2026"
        assert_select "dialog", count: 0
        assert_select "[data-controller='modal month-picker']", count: 0
        assert_select "nav[aria-label=Months] button", count: 0
      end
    end
  end

  describe "the Available bar" do
    let(:month) { Date.new(2026, 9, 1) }

    # An envelope with $100 assigned in September, and `spent` of it spent.
    def envelope_with(name, assigned: 100, spent: 0)
      create(:budget_envelope, budget: budget, name: name).tap do |envelope|
        create(:budget_assignment, envelope: envelope, month: month, amount: assigned) if assigned.positive?
        create(:budget_spend, envelope: envelope, date: month + 4, amount: spent) if spent.positive?
      end
    end

    # The Available cell of an envelope's row.
    def available_cell(envelope)
      "tr#envelope_#{envelope.id} td:nth-child(7)"
    end

    it "is a success bar under the figure when most of what the envelope had is left, with its share as the value" do
      groceries = envelope_with("Groceries", spent: 20)

      get month_path("2026-09")

      assert_select "#{available_cell(groceries)} progress.progress.progress-success[value='80'][max='100'][aria-hidden=true]"
      assert_select "#{available_cell(groceries)} .badge", count: 0
    end

    it "is a warning bar when under a quarter is left, and an empty one when it's all spent" do
      dining_out = envelope_with("Dining out", spent: 76)
      rent = envelope_with("Rent", spent: 100)

      get month_path("2026-09")

      assert_select "#{available_cell(dining_out)} progress.progress-warning[value='24']"
      assert_select "#{available_cell(rent)} progress.progress-warning[value='0']"
    end

    it "counts exactly a quarter as plenty" do
      fuel = envelope_with("Fuel", spent: 75)

      get month_path("2026-09")

      assert_select "#{available_cell(fuel)} progress.progress-success[value='25']"
    end

    it "is a full error bar with the Overspent badge on a line under it, however much it had to spend" do
      dining_out = envelope_with("Dining out", spent: 130)
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)

      get month_path("2026-09")

      [ dining_out, bills ].each do |envelope|
        assert_select "#{available_cell(envelope)} progress.progress-error[value='100'][aria-hidden=true]"
        assert_select "#{available_cell(envelope)} div .badge.badge-error", text: "Overspent", count: 1
        assert_select "#{available_cell(envelope)} span .badge", count: 0
      end
    end

    it "is no bar for a new envelope with nothing to spend and no Spends" do
      new_envelope = create(:budget_envelope, budget: budget, name: "New", starting_balance: 0)

      get month_path("2026-09")

      assert_select "tr#envelope_#{new_envelope.id}", count: 1
      assert_select "tr#envelope_#{new_envelope.id} progress", count: 0
      assert_select "tr#envelope_#{new_envelope.id} .badge", count: 0
    end

    it "has no word for the level: Overspent is the only word, and a bar is hidden from assistive technology" do
      envelope_with("Groceries", spent: 20)
      envelope_with("Dining out", spent: 76)

      get month_path("2026-09")

      assert_select "progress:not([aria-hidden=true])", count: 0
      expect(css_select("table").sole.text).not_to match(/\b(plenty|a little)\b/i)
    end

    it "is under the figure in the Available column, which stays right-aligned" do
      groceries = envelope_with("Groceries", spent: 130)

      get month_path("2026-09")

      assert_select "#{available_cell(groceries)}.text-right progress.ml-auto"
      expect(css_select(available_cell(groceries)).sole.text.squish).to eq("-$30.00 Overspent")
    end

    it "doesn't change the query count with envelopes" do
      envelope_with("Groceries", spent: 20)
      few = count_queries { get month_path("2026-09") }

      envelope_with("Dining out", spent: 130)
      envelope_with("Rent", spent: 100)
      many = count_queries { get month_path("2026-09") }

      expect(many).to eq(few)
    end
  end

  describe "Show details" do
    before { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 25) }

    it "is one button above the table, not pressed, with both of its labels and both of its hints in the markup" do
      get month_path("2026-09")

      assert_select "[data-controller=month-details]" do
        assert_select "button.btn.btn-sm[type=button][aria-pressed=false][data-action='month-details#toggle']", count: 1
        assert_select "button span", text: "Show details"
        assert_select "button span", text: "Hide details"
        assert_select "p", text: "Carried over, Refunded and Reallocated are hidden, so the figures below don't add up on their own."
        assert_select "p", text: "Carried over, Refunded and Reallocated are shown, so the figures below add up to Available."
      end
    end

    it "stacks both hints and both labels in one grid cell, so the table doesn't move when it changes" do
      get month_path("2026-09")

      assert_select "div.grid > p.col-start-1.row-start-1", count: 2
      assert_select "div.grid > p.invisible", count: 1
      assert_select "button span.grid > span.col-start-1.row-start-1", count: 2
      assert_select "button span.grid > span.invisible", count: 1
    end

    it "has Carried over, Refunded and Reallocated as columns only with details on, from sm: up" do
      get month_path("2026-09")

      [ "Carried over", "Refunded", "Reallocated" ].each do |heading|
        assert_select "thead th.hidden.sm\\:in-data-\\[details\\=on\\]\\:table-cell", text: heading
      end
      assert_select "thead th.hidden", count: 3
    end

    it "gives each envelope its own tbody, with a second row of the three figures, labelled, for a phone with details on" do
      get month_path("2026-09")

      assert_select "table tbody", count: 1
      assert_select "tbody tr", count: 2
      assert_select "tbody tr:nth-child(2).hidden td[colspan='4'] dl.grid-cols-3" do
        assert_select "dt", text: "Carried over"
        assert_select "dd", text: "$25.00"
        assert_select "dt", text: "Refunded"
        assert_select "dt", text: "Reallocated"
        assert_select "dd", count: 3
      end
    end

    it "is remembered on <html>, which the layout's head applies before the first paint" do
      get month_path("2026-09")

      assert_select "head script", text: /localStorage\.getItem\("budgie\.monthDetails"\).*dataset\.details/m
    end

    it "isn't on a month with no envelopes" do
      Budget::Envelope.delete_all

      get month_path("2026-09")

      assert_select "[data-controller=month-details]", count: 0
      assert_select "button", text: "Show details", count: 0
    end
  end
end
