require "rails_helper"

RSpec.describe Budget::Deposit, type: :model do
  subject { build(:budget_deposit) }

  it { is_expected.to belong_to(:budget) }

  it "uses the budget_deposits table" do
    expect(Budget::Deposit.table_name).to eq("budget_deposits")
  end

  describe "description" do
    it { is_expected.to validate_presence_of(:description) }

    it "squishes surrounding and repeated whitespace" do
      expect(Budget::Deposit.new(description: "  Pay \n check  ").description).to eq("Pay check")
    end

    it "can't be only whitespace" do
      deposit = build(:budget_deposit, description: " \n ")

      expect(deposit).not_to be_valid
      expect(deposit.errors.full_messages).to eq([ "Description can't be blank" ])
    end
  end

  describe "date" do
    it "is required" do
      deposit = build(:budget_deposit, date: nil, month: Date.new(2026, 9, 1))

      expect(deposit).not_to be_valid
      expect(deposit.errors.full_messages).to eq([ "Date can't be blank" ])
    end

    it "may be any date, in the past or the future" do
      expect(build(:budget_deposit, date: Date.new(1999, 12, 31))).to be_valid
      expect(build(:budget_deposit, date: Date.new(2099, 1, 1))).to be_valid
    end
  end

  describe "month" do
    it "defaults to the month of the date" do
      deposit = build(:budget_deposit, date: Date.new(2026, 9, 30), month: nil)

      expect(deposit).to be_valid
      expect(deposit.month).to eq(Date.new(2026, 9, 1))
    end

    it "is normalized to the 1st of the month" do
      deposit = Budget::Deposit.new(date: "2026-09-30", month: "2026-10-17")

      expect(deposit.month).to eq(Date.new(2026, 10, 1))
    end

    it "may be the month after the date, so a Deposit dated September 30 can count toward October" do
      expect(build(:budget_deposit, date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))).to be_valid
    end

    it "may be January for a Deposit dated in December" do
      expect(build(:budget_deposit, date: Date.new(2026, 12, 20), month: Date.new(2027, 1, 1))).to be_valid
    end

    it "can't be before the month of the date" do
      deposit = build(:budget_deposit, date: Date.new(2026, 9, 1), month: Date.new(2026, 8, 1))

      expect(deposit).not_to be_valid
      expect(deposit.errors.full_messages).to eq([ "Ready to Assign in must be September 2026 or October 2026" ])
    end

    it "can't be two months after the date" do
      deposit = build(:budget_deposit, date: Date.new(2026, 12, 31), month: Date.new(2027, 2, 1))

      expect(deposit).not_to be_valid
      expect(deposit.errors.full_messages).to eq([ "Ready to Assign in must be December 2026 or January 2027" ])
    end

    it "is required when there's no date to default it from" do
      deposit = build(:budget_deposit, date: nil, month: nil)

      expect(deposit).not_to be_valid
      expect(deposit.errors.full_messages).to contain_exactly("Date can't be blank", "Ready to Assign in can't be blank")
    end
  end

  describe "amount" do
    it "is a number above 0" do
      expect(build(:budget_deposit, amount: "0.01")).to be_valid

      [ "0", "-5" ].each do |amount|
        deposit = build(:budget_deposit, amount: amount)

        expect(deposit).not_to be_valid
        expect(deposit.errors.full_messages).to eq([ "Amount must be greater than 0" ])
      end
    end

    it "accepts up to 2 decimal places" do
      deposit = build(:budget_deposit, amount: "1234.56")

      expect(deposit).to be_valid
      expect(deposit.amount).to eq(BigDecimal("1234.56"))
    end

    it "rejects more than 2 decimal places instead of rounding" do
      deposit = build(:budget_deposit, amount: "10.005")

      expect(deposit).not_to be_valid
      expect(deposit.errors.full_messages).to eq([ "Amount can't have more than 2 decimal places" ])
    end

    it "accepts trailing zeros beyond 2 decimal places" do
      expect(build(:budget_deposit, amount: "10.500")).to be_valid
    end

    it "rejects something that isn't a number" do
      [ "$1,000", "", nil, "NaN", "Infinity" ].each do |amount|
        deposit = build(:budget_deposit, amount: amount)

        expect(deposit).not_to be_valid
        expect(deposit.errors.full_messages).to eq([ "Amount is not a number" ])
      end
    end

    it "rejects an amount too large to store" do
      expect(build(:budget_deposit, amount: "10000000000000")).not_to be_valid
      expect(build(:budget_deposit, amount: "9999999999999.99")).to be_valid
    end
  end

  describe "notes" do
    it "are saved as an empty string when left blank" do
      expect(create(:budget_deposit, notes: nil).reload.notes).to eq("")
      expect(create(:budget_deposit, notes: " \n ").reload.notes).to eq("")
    end

    it "keep their text, without the whitespace around it" do
      deposit = build(:budget_deposit, notes: "  Biweekly, from Acme\nplus a bonus \n")

      expect(deposit.notes).to eq("Biweekly, from Acme\nplus a bonus")
    end
  end

  describe ".for_month" do
    it "lists the Deposits that count toward the month, whichever day of it is asked about" do
      budget = create(:budget)
      dated_in_september = create(:budget_deposit, budget: budget, date: Date.new(2026, 9, 3))
      dated_in_august_for_september = create(:budget_deposit, budget: budget, date: Date.new(2026, 8, 31), month: Date.new(2026, 9, 1))
      create(:budget_deposit, budget: budget, date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))
      create(:budget_deposit, budget: budget, date: Date.new(2026, 8, 5))

      expect(budget.deposits.for_month(Date.new(2026, 9, 17))).to contain_exactly(dated_in_september, dated_in_august_for_september)
    end
  end

  describe ".newest_first" do
    it "puts the latest date first, and the most recently entered first within a date" do
      budget = create(:budget)
      earlier_date = create(:budget_deposit, budget: budget, date: Date.new(2026, 9, 1))
      entered_second = create(:budget_deposit, budget: budget, date: Date.new(2026, 9, 30), created_at: Time.zone.local(2026, 9, 30, 12))
      # Saved after the other two, but entered earlier than either.
      entered_first = create(:budget_deposit, budget: budget, date: Date.new(2026, 9, 30), created_at: Time.zone.local(2026, 9, 30, 8))

      expect(budget.deposits.newest_first).to eq([ entered_second, entered_first, earlier_date ])
    end
  end

  describe "database constraints" do
    let(:deposit) { create(:budget_deposit, description: "Paycheck", date: Date.new(2026, 9, 15), amount: 100) }

    # Plain SQL, because the model would normalize or reject most of these values before the database saw them.
    def update_deposit(assignments)
      Budget::Deposit.where(id: deposit.id).update_all(assignments)
    end

    it "rejects a blank description" do
      expect { update_deposit("description = '   '") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_deposits_description_not_blank/)
    end

    it "rejects an amount of zero" do
      expect { update_deposit("amount = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_deposits_amount_positive/)
    end

    it "rejects a negative amount" do
      expect { update_deposit("amount = -0.01") }.to raise_error(ActiveRecord::CheckViolation, /budget_deposits_amount_positive/)
    end

    it "requires notes, which are empty rather than null" do
      expect { update_deposit("notes = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      expect(Budget::Deposit.new.notes).to eq("")
    end

    # One column per example: PostgreSQL aborts the spec's transaction at the first violation.
    %w[ description date month amount ].each do |column|
      it "requires a #{column}" do
        expect { update_deposit("#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "rejects a month that isn't the 1st" do
      expect { update_deposit("month = '2026-09-15'") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_deposits_month_first_of_month/)
    end

    it "rejects a month before the month of the date" do
      expect { update_deposit("month = '2026-08-01'") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_deposits_month_of_date_or_next/)
    end

    it "rejects a month two after the month of the date" do
      expect { update_deposit("month = '2026-11-01'") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_deposits_month_of_date_or_next/)
    end

    it "accepts the month of the date and the month after it" do
      expect { update_deposit("month = '2026-09-01'") }.not_to raise_error
      expect { update_deposit("month = '2026-10-01'") }.not_to raise_error
    end

    it "accepts the month after the date at the end of a year, and from the 31st" do
      december = create(:budget_deposit, date: Date.new(2026, 12, 20))
      january_31 = create(:budget_deposit, date: Date.new(2026, 1, 31))

      expect { Budget::Deposit.where(id: december.id).update_all("month = '2027-01-01'") }.not_to raise_error
      expect { Budget::Deposit.where(id: january_31.id).update_all("month = '2026-02-01'") }.not_to raise_error
    end

    it "keeps a budget with Deposits from being deleted without them" do
      expect { Budget.where(id: deposit.budget_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
