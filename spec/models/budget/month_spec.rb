require "rails_helper"

RSpec.describe Budget::Month, type: :model do
  let(:budget) { create(:budget) }

  # A Deposit counting toward `month`, which is the month of its date unless a different one is given.
  def deposit(amount, date, month: date, budget: self.budget)
    create(:budget_deposit, budget: budget, amount: amount, date: date, month: month)
  end

  # Money assigned to an envelope for a month.
  def assign(envelope, amount, month)
    create(:budget_assignment, envelope: envelope, amount: amount, month: month)
  end

  # Money spent from an envelope on a date.
  def spend(envelope, amount, date)
    create(:budget_spend, envelope: envelope, amount: amount, date: date)
  end

  # Money that came back to an envelope on a date.
  def refund(envelope, amount, date)
    create(:budget_refund, envelope: envelope, amount: amount, date: date)
  end

  # Money moved from one envelope to another on a date.
  def reallocate(from, to, amount, date)
    create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, amount: amount, date: date)
  end

  # A month of the budget, worked out afresh, since a month remembers the figures it has worked out.
  def month_of(date, budget: self.budget)
    Budget::Month.new(budget, date)
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

  describe "Assigned" do
    let(:january) { Date.new(2026, 1, 1) }
    let(:february) { Date.new(2026, 2, 1) }
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 25) }
    let!(:rent) { create(:budget_envelope, budget: budget, name: "Rent", starting_balance: 0) }

    # The worked example: $3,000 is deposited in each of January and February, with $2,800 assigned in January
    # and $3,100 in February.
    context "with two months of Deposits and Assigned amounts" do
      before do
        deposit 3000, january
        deposit 3000, february
        assign groceries, 1300, january
        assign rent, 1500, january
        assign groceries, 1600, february
        assign rent, 1500, february
      end

      it "takes what's assigned out of Ready to Assign in the month it's assigned: January" do
        expect(month_of(january).ready_to_assign)
          .to have_attributes(carried_over: 0, deposited: 3000, assigned: 2800, amount: 200)
      end

      it "carries what's left over into the next month: February" do
        expect(month_of(february).ready_to_assign)
          .to have_attributes(carried_over: 200, deposited: 3000, assigned: 3100, amount: 100)
      end

      it "gives each envelope its Assigned, and an Available of its Starting balance and everything assigned up to the month" do
        groceries_january, rent_january = month_of(january).envelopes
        groceries_february, rent_february = month_of(february).envelopes

        expect(groceries_january).to have_attributes(envelope: groceries, carried_over: 25, assigned: 1300, available: 1325)
        expect(rent_january).to have_attributes(envelope: rent, carried_over: 0, assigned: 1500, available: 1500)
        expect(groceries_february).to have_attributes(carried_over: 1325, assigned: 1600, available: 2925)
        expect(rent_february).to have_attributes(carried_over: 1500, assigned: 1500, available: 3000)
      end

      it "carries Available forward through months with nothing assigned" do
        groceries_april, rent_april = month_of(Date.new(2026, 4, 1)).envelopes

        expect(groceries_april).to have_attributes(carried_over: 2925, assigned: 0, available: 2925)
        expect(rent_april).to have_attributes(carried_over: 3000, assigned: 0, available: 3000)
        expect(month_of(Date.new(2026, 4, 1)).ready_to_assign).to have_attributes(carried_over: 100, assigned: 0, amount: 100)
      end

      it "has nothing assigned before the first Assigned amount, and no Ready to Assign either" do
        groceries_december, = month_of(Date.new(2025, 12, 1)).envelopes

        expect(groceries_december).to have_attributes(carried_over: 25, assigned: 0, available: 25)
        expect(month_of(Date.new(2025, 12, 1)).ready_to_assign).to have_attributes(carried_over: 0, assigned: 0, amount: 0)
      end

      it "follows a change to a past month through every month after it, and leaves the later month's own Assigned as it was" do
        Budget::Assignment.find_by!(envelope: groceries, month: january).update!(amount: 1450)

        expect(month_of(january).ready_to_assign).to have_attributes(assigned: 2950, amount: 50)
        expect(month_of(february).ready_to_assign).to have_attributes(carried_over: 50, assigned: 3100, amount: -50)

        groceries_january, = month_of(january).envelopes
        groceries_february, = month_of(february).envelopes
        expect(groceries_january).to have_attributes(assigned: 1450, available: 1475)
        expect(groceries_february).to have_attributes(carried_over: 1475, assigned: 1600, available: 3075)
      end

      it "goes back up when an Assigned amount is deleted" do
        Budget::Assignment.find_by!(envelope: rent, month: january).destroy!

        expect(month_of(january).ready_to_assign).to have_attributes(assigned: 1300, amount: 1700)
        expect(month_of(february).ready_to_assign).to have_attributes(carried_over: 1700, amount: 1600)
      end

      it "doesn't count another budget's Assigned amounts, or its envelopes" do
        other = create(:budget)
        assign create(:budget_envelope, budget: other), 999, january

        expect(month_of(january).ready_to_assign).to have_attributes(assigned: 2800, amount: 200)
        expect(month_of(january).envelopes.map(&:envelope)).to eq([ groceries, rent ])
      end
    end

    it "lowers Ready to Assign only from the month an Assigned amount is for, however far ahead that is" do
      deposit 1000, january
      assign groceries, 300, Date.new(2026, 3, 1)

      amounts = [ january, february, Date.new(2026, 3, 1) ].map { |date| month_of(date).ready_to_assign.amount }

      expect(amounts).to eq([ 1000, 1000, 700 ])
      expect(month_of(february).envelopes.first).to have_attributes(assigned: 0, available: 25)
      expect(month_of(Date.new(2026, 3, 1)).envelopes.first).to have_attributes(assigned: 300, available: 325)
    end

    it "makes Ready to Assign negative, and the Available of an envelope it wasn't assigned to unchanged" do
      deposit 100, january
      assign groceries, 250, january

      expect(month_of(january).ready_to_assign).to have_attributes(assigned: 250, amount: -150)
      expect(month_of(january).envelopes.last).to have_attributes(envelope: rent, assigned: 0, available: 0)
    end

    it "is over-assigned only when Ready to Assign is below zero, including the cent over, and carries on into the months after" do
      deposit 100, january
      expect(month_of(january).ready_to_assign).not_to be_over_assigned

      assign groceries, 100, january
      expect(month_of(january).ready_to_assign).to have_attributes(amount: 0)
      expect(month_of(january).ready_to_assign).not_to be_over_assigned

      Budget::Assignment.find_by!(envelope: groceries, month: january).update!(amount: "100.01")
      expect(month_of(january).ready_to_assign).to be_over_assigned
      expect(month_of(february).ready_to_assign).to be_over_assigned
    end

    it "assigns a Deposit marked for next month in next month, not in the month of its date" do
      september, october = Date.new(2026, 9, 1), Date.new(2026, 10, 1)
      deposit 1500, Date.new(2026, 9, 15), month: october
      deposit 1500, Date.new(2026, 9, 30), month: october

      expect(month_of(september).ready_to_assign).to have_attributes(deposited: 0, amount: 0)
      expect(month_of(october).ready_to_assign).to have_attributes(deposited: 3000, amount: 3000)

      assign groceries, 3000, october

      expect(month_of(october).ready_to_assign).to have_attributes(deposited: 3000, assigned: 3000, amount: 0)
    end

    it "keeps an envelope Overspent when its Starting balance is below zero and what's assigned doesn't cover it" do
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      assign bills, 10, january

      bills_in_january, = month_of(january).envelopes

      expect(bills_in_january).to have_attributes(carried_over: -30, assigned: 10, available: -20, overspent?: true)
      expect(month_of(february).envelopes.first).to have_attributes(carried_over: -20, assigned: 0, available: -20, overspent?: true)
    end

    it "is no longer Overspent once enough is assigned" do
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      assign bills, 30, january

      expect(month_of(january).envelopes.first).to have_attributes(available: 0, overspent?: false)
    end

    it "adds cents exactly, as BigDecimal" do
      assign groceries, "0.10", january
      assign groceries, "0.20", february

      line = month_of(february).envelopes.first

      expect(line.available).to be_a(BigDecimal)
      expect(line.available).to eq(BigDecimal("25.30"))
      expect(month_of(february).ready_to_assign.assigned).to be_a(BigDecimal)
      expect(month_of(january).ready_to_assign.assigned).to eq(BigDecimal("0.10"))
    end

    it "is zero, and BigDecimal, for a budget with no Assigned amounts" do
      line = month_of(january).envelopes.first

      expect(month_of(january).ready_to_assign.assigned).to be_a(BigDecimal)
      expect(line.assigned).to be_a(BigDecimal)
      expect(line.assigned).to eq(0)
    end
  end

  describe "Spent" do
    let(:january) { Date.new(2026, 1, 1) }
    let(:february) { Date.new(2026, 2, 1) }
    let(:march) { Date.new(2026, 3, 1) }
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 0) }

    # The Groceries worked example: $400 is assigned in each of January to March, and $350, $480 and $300 are spent.
    def set_up_the_groceries_example
      [ january, february, march ].each { |month| assign groceries, 400, month }
      spend groceries, 350, Date.new(2026, 1, 20)
      spend groceries, 480, Date.new(2026, 2, 14)
      spend groceries, 300, Date.new(2026, 3, 3)
    end

    # What the envelope shows in each of January to March, as [ carried over, assigned, spent, available ].
    def groceries_figures
      [ january, february, march ].map do |month|
        line = month_of(month).envelopes.find { |envelope_line| envelope_line.envelope == groceries }
        [ line.carried_over, line.assigned, line.spent, line.available ]
      end
    end

    it "gives the Groceries example: Carried over $0, $50 and -$30, and Available $50, -$30 and $70" do
      set_up_the_groceries_example

      expect(groceries_figures).to eq([
        [ 0, 400, 350, 50 ],
        [ 50, 400, 480, -30 ],
        [ -30, 400, 300, 70 ]
      ])
    end

    it "marks February Overspent in the Groceries example, and neither January nor March" do
      set_up_the_groceries_example

      expect([ january, february, march ].map { |month| month_of(month).envelopes.first.overspent? }).to eq([ false, true, false ])
    end

    it "shifts every month's Available by exactly the Starting balance: $25 gives $75, -$5 and $95" do
      set_up_the_groceries_example
      groceries.update!(starting_balance: 25)

      expect(groceries_figures).to eq([
        [ 25, 400, 350, 75 ],
        [ 75, 400, 480, -5 ],
        [ -5, 400, 300, 95 ]
      ])
    end

    it "carries a balance forward through months with no records, and into months before any" do
      set_up_the_groceries_example

      april, may = [ Date.new(2026, 4, 1), Date.new(2026, 5, 1) ].map { |month| month_of(month).envelopes.first }
      december = month_of(Date.new(2025, 12, 1)).envelopes.first

      expect(april).to have_attributes(carried_over: 70, assigned: 0, spent: 0, available: 70)
      expect(may).to have_attributes(carried_over: 70, assigned: 0, spent: 0, available: 70)
      expect(december).to have_attributes(carried_over: 0, assigned: 0, spent: 0, available: 0)
    end

    it "counts a Spend in the month it's dated in: the 1st and the last day, and not the days either side" do
      spend groceries, 1, Date.new(2026, 1, 31)
      spend groceries, 10, Date.new(2026, 2, 1)
      spend groceries, 100, Date.new(2026, 2, 28)
      spend groceries, 1000, Date.new(2026, 3, 1)

      expect(groceries_figures).to eq([
        [ 0, 0, 1, -1 ],
        [ -1, 0, 110, -111 ],
        [ -111, 0, 1000, -1111 ]
      ])
    end

    it "carries Available into the months after, so a Spend dated at the end of a year lowers the next year's too" do
      spend groceries, 40, Date.new(2026, 12, 31)

      expect(month_of(Date.new(2026, 12, 1)).envelopes.first).to have_attributes(spent: 40, available: -40)
      expect(month_of(Date.new(2027, 1, 1)).envelopes.first).to have_attributes(carried_over: -40, spent: 0, available: -40)
    end

    it "takes a Spend out of Available without anything assigned, and a Starting balance covers it" do
      groceries.update!(starting_balance: 100)
      spend groceries, 30, Date.new(2026, 1, 5)

      expect(month_of(january).envelopes.first).to have_attributes(carried_over: 100, assigned: 0, spent: 30, available: 70, overspent?: false)
    end

    it "follows a Spend changed or deleted through every month after it" do
      set_up_the_groceries_example
      Budget::Spend.find_by!(envelope: groceries, amount: 480).update!(amount: 430)

      expect(groceries_figures.map(&:last)).to eq([ 50, 20, 120 ])

      Budget::Spend.find_by!(envelope: groceries, amount: 350).destroy!

      expect(groceries_figures.map(&:last)).to eq([ 400, 370, 470 ])
    end

    it "follows a Spend moved to another month, in both" do
      set_up_the_groceries_example
      Budget::Spend.find_by!(envelope: groceries, amount: 350).update!(date: Date.new(2026, 2, 2))

      expect(groceries_figures).to eq([
        [ 0, 400, 0, 400 ],
        [ 400, 400, 830, -30 ],
        [ -30, 400, 300, 70 ]
      ])
    end

    it "adds up each envelope's Spends on their own" do
      rent = create(:budget_envelope, budget: budget, name: "Rent", starting_balance: 0)
      spend groceries, 60, Date.new(2026, 1, 5)
      spend groceries, 40, Date.new(2026, 1, 25)
      spend rent, 1500, Date.new(2026, 1, 1)

      groceries_line, rent_line = month_of(january).envelopes

      expect(groceries_line).to have_attributes(spent: 100, available: -100)
      expect(rent_line).to have_attributes(spent: 1500, available: -1500)
    end

    it "doesn't change Ready to Assign, in the month of a Spend or after it" do
      deposit 3000, january
      assign groceries, 400, january
      before = [ january, february ].map { |month| month_of(month).ready_to_assign }

      spend groceries, 350, Date.new(2026, 1, 20)

      expect([ january, february ].map { |month| month_of(month).ready_to_assign }).to eq(before)
      expect(month_of(january).ready_to_assign).to have_attributes(carried_over: 0, deposited: 3000, assigned: 400, amount: 2600)
    end

    it "doesn't count another budget's Spends" do
      other = create(:budget_envelope, budget: create(:budget), name: "Groceries")
      spend other, 999, Date.new(2026, 1, 20)
      spend groceries, 25, Date.new(2026, 1, 20)

      expect(month_of(january).envelopes.sole).to have_attributes(spent: 25, available: -25)
    end

    it "adds cents exactly, as BigDecimal" do
      spend groceries, "0.10", Date.new(2026, 1, 5)
      spend groceries, "0.20", Date.new(2026, 2, 5)

      line = month_of(february).envelopes.first

      expect(line.spent).to be_a(BigDecimal)
      expect(line.spent).to eq(BigDecimal("0.20"))
      expect(line.available).to eq(BigDecimal("-0.30"))
    end

    it "is zero, and BigDecimal, for an envelope with no Spends" do
      line = month_of(january).envelopes.first

      expect(line.spent).to be_a(BigDecimal)
      expect(line.spent).to eq(0)
    end

    it "is on the envelope's line, found by its id" do
      spend groceries, 12.5, Date.new(2026, 1, 5)

      expect(month_of(january).envelope_line(groceries.id)).to have_attributes(spent: BigDecimal("12.5"), available: BigDecimal("-12.5"))
    end
  end

  describe "Refunded" do
    let(:january) { Date.new(2026, 1, 1) }
    let(:february) { Date.new(2026, 2, 1) }
    let(:march) { Date.new(2026, 3, 1) }
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 0) }

    # The Groceries worked example, as for Spent: $400 is assigned in each of January to March, and $350, $480 and $300
    # are spent.
    def set_up_the_groceries_example
      [ january, february, march ].each { |month| assign groceries, 400, month }
      spend groceries, 350, Date.new(2026, 1, 20)
      spend groceries, 480, Date.new(2026, 2, 14)
      spend groceries, 300, Date.new(2026, 3, 3)
    end

    # What the envelope shows in each of January to March, as [ carried over, assigned, spent, refunded, available ].
    def groceries_figures
      [ january, february, march ].map do |month|
        line = month_of(month).envelopes.find { |envelope_line| envelope_line.envelope == groceries }
        [ line.carried_over, line.assigned, line.spent, line.refunded, line.available ]
      end
    end

    it "gives the Groceries example a $50 Refund in February: Available $50, $20 and $120, so February is no longer Overspent" do
      set_up_the_groceries_example
      refund groceries, 50, Date.new(2026, 2, 20)

      expect(groceries_figures).to eq([
        [ 0, 400, 350, 0, 50 ],
        [ 50, 400, 480, 50, 20 ],
        [ 20, 400, 300, 0, 120 ]
      ])
      expect([ january, february, march ].map { |month| month_of(month).envelopes.first.overspent? }).to eq([ false, false, false ])
    end

    it "leaves Ready to Assign exactly as it was, in every month, with the Refund and without it" do
      set_up_the_groceries_example
      deposit 3000, january
      deposit 3000, february
      without_the_refund = [ january, february, march ].map { |month| month_of(month).ready_to_assign }

      refund groceries, 50, Date.new(2026, 2, 20)

      expect([ january, february, march ].map { |month| month_of(month).ready_to_assign }).to eq(without_the_refund)
      expect(month_of(february).ready_to_assign).to have_attributes(carried_over: 2600, deposited: 3000, assigned: 400, amount: 5200)
    end

    it "counts a Refund in the month it's dated in: the 1st and the last day, and not the days either side" do
      refund groceries, 1, Date.new(2026, 1, 31)
      refund groceries, 10, Date.new(2026, 2, 1)
      refund groceries, 100, Date.new(2026, 2, 28)
      refund groceries, 1000, Date.new(2026, 3, 1)

      expect(groceries_figures).to eq([
        [ 0, 0, 0, 1, 1 ],
        [ 1, 0, 0, 110, 111 ],
        [ 111, 0, 0, 1000, 1111 ]
      ])
    end

    it "carries Available into the months after, so a Refund dated at the end of a year raises the next year's too" do
      refund groceries, 40, Date.new(2026, 12, 31)

      expect(month_of(Date.new(2026, 12, 1)).envelopes.first).to have_attributes(refunded: 40, available: 40)
      expect(month_of(Date.new(2027, 1, 1)).envelopes.first).to have_attributes(carried_over: 40, refunded: 0, available: 40)
    end

    it "has nothing Refunded in the months before it, and carries its balance forward through months with none" do
      refund groceries, 25, Date.new(2026, 2, 3)

      expect(month_of(january).envelopes.first).to have_attributes(carried_over: 0, refunded: 0, available: 0)
      expect(month_of(Date.new(2026, 5, 1)).envelopes.first).to have_attributes(carried_over: 25, refunded: 0, available: 25)
    end

    it "brings back an envelope that was Overspent, and can take it above zero" do
      groceries.update!(starting_balance: -30)

      expect(month_of(january).envelopes.first).to have_attributes(available: -30, overspent?: true)

      refund groceries, 30, Date.new(2026, 1, 10)
      expect(month_of(january).envelopes.first).to have_attributes(available: 0, overspent?: false)

      refund groceries, 5, Date.new(2026, 1, 11)
      expect(month_of(january).envelopes.first).to have_attributes(available: 5, overspent?: false)
    end

    it "follows a Refund changed, moved to another month, or deleted, through every month after it" do
      set_up_the_groceries_example
      refund groceries, 50, Date.new(2026, 2, 20)

      Budget::Refund.find_by!(envelope: groceries).update!(amount: 80)
      expect(groceries_figures.map(&:last)).to eq([ 50, 50, 150 ])

      Budget::Refund.find_by!(envelope: groceries).update!(date: Date.new(2026, 3, 2))
      expect(groceries_figures).to eq([
        [ 0, 400, 350, 0, 50 ],
        [ 50, 400, 480, 0, -30 ],
        [ -30, 400, 300, 80, 150 ]
      ])

      Budget::Refund.find_by!(envelope: groceries).destroy!
      expect(groceries_figures.map(&:last)).to eq([ 50, -30, 70 ])
    end

    it "adds up each envelope's Refunds on their own" do
      rent = create(:budget_envelope, budget: budget, name: "Rent", starting_balance: 0)
      refund groceries, 60, Date.new(2026, 1, 5)
      refund groceries, 40, Date.new(2026, 1, 25)
      refund rent, 1500, Date.new(2026, 1, 1)

      groceries_line, rent_line = month_of(january).envelopes

      expect(groceries_line).to have_attributes(refunded: 100, available: 100)
      expect(rent_line).to have_attributes(refunded: 1500, available: 1500)
    end

    it "doesn't count another budget's Refunds" do
      other = create(:budget_envelope, budget: create(:budget), name: "Groceries")
      refund other, 999, Date.new(2026, 1, 20)
      refund groceries, 25, Date.new(2026, 1, 20)

      expect(month_of(january).envelopes.sole).to have_attributes(refunded: 25, available: 25)
    end

    it "adds cents exactly, as BigDecimal" do
      refund groceries, "0.10", Date.new(2026, 1, 5)
      refund groceries, "0.20", Date.new(2026, 2, 5)

      line = month_of(february).envelopes.first

      expect(line.refunded).to be_a(BigDecimal)
      expect(line.refunded).to eq(BigDecimal("0.20"))
      expect(line.available).to eq(BigDecimal("0.30"))
    end

    it "is zero, and BigDecimal, for an envelope with no Refunds" do
      line = month_of(january).envelopes.first

      expect(line.refunded).to be_a(BigDecimal)
      expect(line.refunded).to eq(0)
    end

    it "is on the envelope's line, found by its id" do
      refund groceries, 12.5, Date.new(2026, 1, 5)

      expect(month_of(january).envelope_line(groceries.id)).to have_attributes(refunded: BigDecimal("12.5"), available: BigDecimal("12.5"))
    end
  end

  describe "Reallocated" do
    let(:january) { Date.new(2026, 1, 1) }
    let(:february) { Date.new(2026, 2, 1) }
    let(:march) { Date.new(2026, 3, 1) }
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 0) }
    let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out", starting_balance: 0) }

    # The Groceries worked example, as for Spent: $400 is assigned in each of January to March, and $350, $480 and $300
    # are spent. Dining out has $200 assigned in each of them and nothing spent.
    def set_up_the_example
      [ january, february, march ].each do |month|
        assign groceries, 400, month
        assign dining_out, 200, month
      end
      spend groceries, 350, Date.new(2026, 1, 20)
      spend groceries, 480, Date.new(2026, 2, 14)
      spend groceries, 300, Date.new(2026, 3, 3)
    end

    def line_of(envelope, month)
      month_of(month).envelopes.find { |line| line.envelope == envelope }
    end

    # What the envelope shows in each of January to March, as [ carried over, reallocated, available ].
    def figures_of(envelope)
      [ january, february, march ].map do |month|
        line = line_of(envelope, month)
        [ line.carried_over, line.reallocated, line.available ]
      end
    end

    it "gives Groceries a $30 Reallocation from Dining out in February: Available $50, $0 and $100, so February is no longer Overspent" do
      set_up_the_example
      reallocate dining_out, groceries, 30, Date.new(2026, 2, 20)

      expect(figures_of(groceries)).to eq([ [ 0, 0, 50 ], [ 50, 30, 0 ], [ 0, 0, 100 ] ])
      expect(figures_of(dining_out)).to eq([ [ 0, 0, 200 ], [ 200, -30, 370 ], [ 370, 0, 570 ] ])
      expect([ january, february, march ].map { |month| line_of(groceries, month).overspent? }).to eq([ false, false, false ])
    end

    it "is Reallocated $0 in every month when nothing has been reallocated, and changes no Available" do
      set_up_the_example

      expect(figures_of(groceries)).to eq([ [ 0, 0, 50 ], [ 50, 0, -30 ], [ -30, 0, 70 ] ])
      expect(line_of(groceries, february)).to be_overspent
    end

    it "leaves Ready to Assign exactly as it was, in every month, with the Reallocation and without it" do
      set_up_the_example
      deposit 3000, january
      deposit 3000, february
      without_it = [ january, february, march ].map { |month| month_of(month).ready_to_assign.to_h }

      reallocate dining_out, groceries, 30, Date.new(2026, 2, 20)

      expect([ january, february, march ].map { |month| month_of(month).ready_to_assign.to_h }).to eq(without_it)
    end

    it "keeps the two envelopes' Available adding up to the same in every month" do
      set_up_the_example
      without_it = [ january, february, march ].map { |month| month_of(month).envelopes.sum(&:available) }

      reallocate dining_out, groceries, 30, Date.new(2026, 2, 20)

      expect([ january, february, march ].map { |month| month_of(month).envelopes.sum(&:available) }).to eq(without_it)
    end

    it "can leave the From envelope Overspent, and shows that" do
      reallocate groceries, dining_out, 75, Date.new(2026, 2, 10)

      expect(line_of(groceries, february)).to have_attributes(reallocated: -75, available: -75)
      expect(line_of(groceries, february)).to be_overspent
      expect(line_of(dining_out, february)).to have_attributes(reallocated: 75, available: 75)
    end

    it "adds up several Reallocations in and out of an envelope in the same month" do
      other = create(:budget_envelope, budget: budget, name: "Fuel")
      reallocate dining_out, groceries, 30, Date.new(2026, 2, 3)
      reallocate dining_out, groceries, 12.5, Date.new(2026, 2, 28)
      reallocate groceries, other, 4.25, Date.new(2026, 2, 15)

      expect(line_of(groceries, february).reallocated).to eq(BigDecimal("38.25"))
      expect(line_of(dining_out, february).reallocated).to eq(BigDecimal("-42.5"))
      expect(line_of(other, february).reallocated).to eq(BigDecimal("4.25"))
    end

    it "counts in the month of its date: the 1st and the last day of it, and not the days either side" do
      reallocate dining_out, groceries, 1, Date.new(2026, 1, 31)
      reallocate dining_out, groceries, 10, Date.new(2026, 2, 1)
      reallocate dining_out, groceries, 100, Date.new(2026, 2, 28)
      reallocate dining_out, groceries, 1000, Date.new(2026, 3, 1)

      expect(figures_of(groceries)).to eq([ [ 0, 1, 1 ], [ 1, 110, 111 ], [ 111, 1000, 1111 ] ])
      expect(figures_of(dining_out)).to eq([ [ 0, -1, -1 ], [ -1, -110, -111 ], [ -111, -1000, -1111 ] ])
    end

    it "counts in every month after the one it's dated in, and in none before" do
      reallocate dining_out, groceries, 30, Date.new(2026, 2, 20)

      expect(line_of(groceries, january)).to have_attributes(carried_over: 0, reallocated: 0, available: 0)
      expect(line_of(groceries, Date.new(2026, 12, 1))).to have_attributes(carried_over: 30, reallocated: 0, available: 30)
    end

    it "counts a Reallocation made in a month long after the others, across the end of a year" do
      reallocate dining_out, groceries, 30, Date.new(2025, 12, 31)

      expect(line_of(groceries, Date.new(2026, 1, 1))).to have_attributes(carried_over: 30, reallocated: 0)
      expect(line_of(groceries, Date.new(2025, 12, 1))).to have_attributes(carried_over: 0, reallocated: 30)
    end

    it "adds to the Starting balance" do
      groceries.update!(starting_balance: 20)
      reallocate dining_out, groceries, 30, Date.new(2026, 2, 20)

      expect(line_of(groceries, february)).to have_attributes(carried_over: 20, reallocated: 30, available: 50)
    end

    it "doesn't count another budget's Reallocations" do
      other_budget = create(:budget)
      from = create(:budget_envelope, budget: other_budget)
      to = create(:budget_envelope, budget: other_budget)
      reallocate from, to, 30, Date.new(2026, 2, 20)

      expect(figures_of(groceries)).to eq([ [ 0, 0, 0 ] ] * 3)
      expect(month_of(february, budget: other_budget).envelopes.map(&:reallocated)).to contain_exactly(-30, 30)
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
        ready_to_assign = figures.ready_to_assign
        [ ready_to_assign.amount, ready_to_assign.carried_over, ready_to_assign.deposited, ready_to_assign.assigned ]
        figures.envelopes.each { |line| [ line.carried_over, line.assigned, line.spent, line.refunded, line.reallocated, line.available ] }
      end
    end

    it "doesn't grow with the months of history: 1 month of Deposits, Assigned amounts, Spends, Refunds and Reallocations costs what 36 do" do
      envelope = create(:budget_envelope, budget: budget)
      other = create(:budget_envelope, budget: budget)
      deposit 100, month
      assign envelope, 10, month
      spend envelope, 5, month
      refund envelope, 2, month
      reallocate envelope, other, 1, month
      with_one_month = queries_for_every_figure

      (1..35).each do |months_ago|
        deposit 100, month << months_ago
        assign envelope, 10, month << months_ago
        spend envelope, 5, month << months_ago
        refund envelope, 2, month << months_ago
        reallocate envelope, other, 1, month << months_ago
        reallocate other, envelope, 1, month << months_ago
      end
      with_thirty_six = queries_for_every_figure

      expect(with_one_month).to be_positive
      expect(with_thirty_six).to eq(with_one_month)
    end

    it "doesn't grow with the envelopes: 1 envelope with an Assigned amount, a Spend, a Refund and a Reallocation costs what 20 do" do
      envelope = create(:budget_envelope, budget: budget)
      other = create(:budget_envelope, budget: budget)
      assign envelope, 10, month
      spend envelope, 5, month
      refund envelope, 2, month
      reallocate envelope, other, 1, month
      deposit 100, month
      with_one_envelope = queries_for_every_figure

      create_list(:budget_envelope, 18, budget: budget).each do |another|
        assign another, 10, month
        spend another, 5, month
        refund another, 2, month
        reallocate another, envelope, 1, month
      end
      with_twenty = queries_for_every_figure

      expect(with_one_envelope).to be_positive
      expect(with_twenty).to eq(with_one_envelope)
    end

    it "costs the same whether or not anything has been assigned, spent, refunded or reallocated" do
      create(:budget_envelope, budget: budget)
      deposit 100, month
      with_nothing_recorded = queries_for_every_figure

      assign budget.envelopes.first, 10, month
      with_something_assigned = queries_for_every_figure

      spend budget.envelopes.first, 5, month
      with_something_spent = queries_for_every_figure

      refund budget.envelopes.first, 2, month
      with_something_refunded = queries_for_every_figure

      reallocate budget.envelopes.first, create(:budget_envelope, budget: budget), 1, month
      with_something_reallocated = queries_for_every_figure

      expect(with_something_assigned).to eq(with_nothing_recorded)
      expect(with_something_spent).to eq(with_nothing_recorded)
      expect(with_something_refunded).to eq(with_nothing_recorded)
      expect(with_something_reallocated).to eq(with_nothing_recorded)
    end

    it "asks the database nothing until a figure is wanted, and only once for a figure a page reads again" do
      envelope = create(:budget_envelope, budget: budget)
      assign envelope, 10, month
      spend envelope, 5, month
      refund envelope, 2, month
      reallocate envelope, create(:budget_envelope, budget: budget), 1, month
      deposit 100, month
      figures = Budget::Month.new(budget, month)

      expect(count_queries { figures.previous.next.name }).to eq(0)

      figures.ready_to_assign
      figures.envelopes
      expect(count_queries { figures.ready_to_assign.assigned; figures.envelopes.map { |line| [ line.assigned, line.spent, line.refunded, line.reallocated ] } }).to eq(0)
    end
  end

  describe "#envelope_line" do
    it "is one of the month's lines, found by the envelope's id, whether it's given as a number or as text" do
      groceries = create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 25)
      create(:budget_envelope, budget: budget, name: "Rent")
      assign groceries, 300, Date.new(2026, 9, 1)

      line = Budget::Month.new(budget, Date.new(2026, 9, 1)).envelope_line(groceries.id)

      expect(line).to have_attributes(envelope: groceries, carried_over: 25, assigned: 300, available: 325)
      expect(Budget::Month.new(budget, Date.new(2026, 9, 1)).envelope_line(groceries.id.to_s)).to eq(line)
    end

    it "is not found for another budget's envelope, one that doesn't exist, or something that isn't an id" do
      others = create(:budget_envelope, name: "Someone else's")
      month = Budget::Month.new(budget, Date.new(2026, 9, 1))

      [ others.id, 0, "not-an-id", nil ].each do |id|
        expect { month.envelope_line(id) }.to raise_error(ActiveRecord::RecordNotFound)
      end
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
