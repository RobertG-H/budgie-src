require "rails_helper"

RSpec.describe Budget::Month, type: :model do
  let(:budget) { create(:budget) }

  # A Deposit counting toward `month`, which is the month of its date unless a different one is given.
  def deposit(amount, date, month: date, budget: self.budget)
    create(:budget_deposit, budget: budget, amount: amount, date: date, month: month)
  end

  describe "#ready_to_assign" do
    it "is every Deposit for the month and the months before it, with what was carried over and what was deposited" do
      deposit 1000, Date.new(2026, 8, 1)
      deposit 250.50, Date.new(2026, 8, 20)
      deposit 3000, Date.new(2026, 9, 1)
      deposit 500, Date.new(2026, 10, 1)

      ready_to_assign = Budget::Month.new(budget, Date.new(2026, 9, 17)).ready_to_assign

      expect(ready_to_assign).to have_attributes(
        carried_over: BigDecimal("1250.50"), deposited: BigDecimal("3000"), amount: BigDecimal("4250.50")
      )
    end

    it "counts a Deposit dated in September and marked for October in October's, and in neither of September's" do
      deposit 3000, Date.new(2026, 9, 30), month: Date.new(2026, 10, 1)

      september = Budget::Month.new(budget, Date.new(2026, 9, 1)).ready_to_assign
      october = Budget::Month.new(budget, Date.new(2026, 10, 1)).ready_to_assign

      expect(september).to have_attributes(carried_over: 0, deposited: 0, amount: 0)
      expect(october).to have_attributes(carried_over: 0, deposited: 3000, amount: 3000)
    end

    it "follows a Deposit moved between the two months it can count toward, in both" do
      paycheck = deposit 3000, Date.new(2026, 9, 30)
      september = -> { Budget::Month.new(budget, Date.new(2026, 9, 1)).ready_to_assign }
      october = -> { Budget::Month.new(budget, Date.new(2026, 10, 1)).ready_to_assign }

      expect(september.call).to have_attributes(deposited: 3000, amount: 3000)
      expect(october.call).to have_attributes(carried_over: 3000, deposited: 0, amount: 3000)

      paycheck.update!(month: Date.new(2026, 10, 1))

      expect(september.call).to have_attributes(deposited: 0, amount: 0)
      expect(october.call).to have_attributes(carried_over: 0, deposited: 3000, amount: 3000)
    end

    it "carries forward through months with no Deposits" do
      deposit 3000, Date.new(2026, 7, 1)

      december = Budget::Month.new(budget, Date.new(2026, 12, 1)).ready_to_assign

      expect(december).to have_attributes(carried_over: 3000, deposited: 0, amount: 3000)
    end

    it "is zero before the first Deposit, and for a budget with none" do
      deposit 3000, Date.new(2026, 7, 1)

      expect(Budget::Month.new(budget, Date.new(2026, 6, 1)).ready_to_assign).to have_attributes(carried_over: 0, deposited: 0, amount: 0)
      expect(Budget::Month.new(create(:budget), Date.new(2026, 9, 1)).ready_to_assign).to have_attributes(amount: 0)
    end

    it "counts only the budget's own Deposits" do
      deposit 3000, Date.new(2026, 9, 1)
      deposit 999, Date.new(2026, 9, 1), budget: create(:budget)

      expect(Budget::Month.new(budget, Date.new(2026, 9, 1)).ready_to_assign.amount).to eq(3000)
    end

    it "adds cents exactly, as BigDecimal" do
      deposit "0.10", Date.new(2026, 9, 1)
      deposit "0.20", Date.new(2026, 9, 2)

      amount = Budget::Month.new(budget, Date.new(2026, 9, 1)).ready_to_assign.amount

      expect(amount).to be_a(BigDecimal)
      expect(amount).to eq(BigDecimal("0.30"))
    end
  end

  describe "the month itself" do
    it "is the calendar month containing the date it's given" do
      expect(Budget::Month.new(budget, Date.new(2026, 9, 17)).date).to eq(Date.new(2026, 9, 1))
      expect(Budget::Month.new(budget, Date.new(2026, 9, 30)).date).to eq(Date.new(2026, 9, 1))
      expect(Budget::Month.new(budget, Time.zone.local(2026, 9, 30, 23, 59)).date).to eq(Date.new(2026, 9, 1))
    end

    it "is named for its month and year" do
      expect(Budget::Month.new(budget, Date.new(2026, 9, 17)).name).to eq("September 2026")
    end

    it "is identified in a URL by its year and month" do
      expect(Budget::Month.new(budget, Date.new(2026, 9, 17)).to_param).to eq("2026-09")
      expect(Budget::Month.new(budget, Date.new(2026, 1, 1)).to_param).to eq("2026-01")
    end

    it "has a previous and a next month, across the end of a year" do
      january = Budget::Month.new(budget, Date.new(2026, 1, 31))
      december = Budget::Month.new(budget, Date.new(2026, 12, 1))

      expect(january.previous.date).to eq(Date.new(2025, 12, 1))
      expect(january.next.date).to eq(Date.new(2026, 2, 1))
      expect(december.next.date).to eq(Date.new(2027, 1, 1))
      expect(december.previous.date).to eq(Date.new(2026, 11, 1))
    end

    it "keeps its budget when it moves, and isn't bounded in either direction" do
      month = Budget::Month.new(budget, Date.new(2026, 9, 1))

      expect(month.previous.budget).to eq(budget)
      expect(month.next.budget).to eq(budget)
      expect((1..600).inject(month) { |moved, _| moved.previous }.date).to eq(Date.new(1976, 9, 1))
      expect((1..600).inject(month) { |moved, _| moved.next }.date).to eq(Date.new(2076, 9, 1))
    end
  end

  describe "the current month" do
    # 00:30 UTC on October 1 is still the evening of September 30 in Eastern time, which is the app's time zone.
    before { travel_to Time.utc(2026, 10, 1, 0, 30) }

    it "is the month it is in Eastern time" do
      expect(Budget::Month.new(budget, Date.new(2026, 9, 1))).to be_current
      expect(Budget::Month.new(budget, Date.new(2026, 10, 1))).not_to be_current
    end

    it "can be reached from any other month" do
      month = Budget::Month.new(budget, Date.new(2030, 3, 1))

      expect(month.current.date).to eq(Date.new(2026, 9, 1))
      expect(month.current.budget).to eq(budget)
    end
  end

  describe ".from_param" do
    it "reads a year and a month" do
      month = Budget::Month.from_param(budget, "2026-09")

      expect(month).to be_a(Budget::Month)
      expect(month).to have_attributes(date: Date.new(2026, 9, 1), budget: budget)
    end

    it "reads the month that to_param writes" do
      month = Budget::Month.new(budget, Date.new(2026, 1, 20))

      expect(Budget::Month.from_param(budget, month.to_param).date).to eq(Date.new(2026, 1, 1))
    end

    # A date field accepts years up to 275760, and a Deposit can be dated in any of them.
    it "reads years of more than four digits, so every date a form can send has a month to be found in" do
      { "10000-01" => Date.new(10_000, 1, 1), "20266-09" => Date.new(20_266, 9, 1), "275760-09" => Date.new(275_760, 9, 1) }.each do |param, date|
        month = Budget::Month.from_param(budget, param)

        expect(month.date).to eq(date)
        expect(month.to_param).to eq(param)
      end
    end

    it "can move on from the last year with four digits, and the first with five" do
      expect(Budget::Month.from_param(budget, "9999-12").next.to_param).to eq("10000-01")
      expect(Budget::Month.from_param(budget, "10000-01").previous.to_param).to eq("9999-12")
    end

    [ "2026-13", "2026-00", "2026-9", "26-09", "2026-09-01", "2026-09\n", " 2026-09", "0000-05", "-001-05", "1000000-01", "September", "", nil ].each do |param|
      it "reads nothing from #{param.inspect}" do
        expect(Budget::Month.from_param(budget, param)).to be_nil
      end
    end
  end

  describe "the number of queries" do
    let(:month) { Date.new(2029, 9, 1) }

    # Everything a page asks of a month, on a new one, since a month remembers what it has worked out.
    def queries_for_every_figure
      count_queries do
        figures = Budget::Month.new(budget, month)
        figures.ready_to_assign.amount
        figures.envelopes.each { |line| [ line.carried_over, line.available ] }
      end
    end

    it "doesn't grow with the months of history: 1 month of Deposits costs what 36 do" do
      create(:budget_envelope, budget: budget)
      deposit 100, month
      with_one_month = queries_for_every_figure

      (1..35).each { |months_ago| deposit 100, month << months_ago }
      with_thirty_six = queries_for_every_figure

      expect(with_one_month).to be_positive
      expect(with_thirty_six).to eq(with_one_month)
    end

    it "doesn't grow with the envelopes: 1 envelope costs what 20 do" do
      create(:budget_envelope, budget: budget)
      deposit 100, month
      with_one_envelope = queries_for_every_figure

      create_list(:budget_envelope, 19, budget: budget)
      with_twenty = queries_for_every_figure

      expect(with_one_envelope).to be_positive
      expect(with_twenty).to eq(with_one_envelope)
    end

    it "asks the database nothing until a figure is wanted, and only once for a figure a page reads again" do
      create(:budget_envelope, budget: budget)
      deposit 100, month
      figures = Budget::Month.new(budget, month)

      expect(count_queries { figures.previous.next.name }).to eq(0)

      figures.ready_to_assign
      figures.envelopes
      expect(count_queries { figures.ready_to_assign.amount; figures.envelopes.size }).to eq(0)
    end
  end

  describe "#envelopes" do
    it "lists the budget's envelopes alphabetically, ignoring case, and no one else's" do
      rent = create(:budget_envelope, budget: budget, name: "rent")
      bills = create(:budget_envelope, budget: budget, name: "Bills")
      groceries = create(:budget_envelope, budget: budget, name: "Groceries")
      create(:budget_envelope, name: "Someone else's")

      lines = Budget::Month.new(budget, Date.new(2026, 9, 1)).envelopes

      expect(lines.map(&:envelope)).to eq([ bills, groceries, rent ])
    end

    it "has nothing to list for a budget without envelopes" do
      expect(Budget::Month.new(budget, Date.new(2026, 9, 1)).envelopes).to eq([])
    end

    it "has each envelope's Starting balance as Available, and as Carried over, in every month" do
      create(:budget_envelope, budget: budget, name: "Rent", starting_balance: "1234.50")

      [ Date.new(1999, 1, 1), Date.new(2026, 9, 17), Date.new(2060, 12, 31) ].each do |date|
        line = Budget::Month.new(budget, date).envelopes.sole

        expect(line).to have_attributes(carried_over: BigDecimal("1234.50"), available: BigDecimal("1234.50"))
      end
    end

    it "keeps a negative Starting balance negative, which is Overspent" do
      create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      create(:budget_envelope, budget: budget, name: "Fuel", starting_balance: 0)
      create(:budget_envelope, budget: budget, name: "Rent", starting_balance: 12)

      bills, fuel, rent = Budget::Month.new(budget, Date.new(2026, 9, 1)).envelopes

      expect(bills).to have_attributes(carried_over: -30, available: -30, overspent?: true)
      expect(fuel).to have_attributes(available: 0, overspent?: false)
      expect(rent).to have_attributes(available: 12, overspent?: false)
    end
  end
end
