require "rails_helper"

RSpec.describe Budget::Assignment, type: :model do
  subject { build(:budget_assignment) }

  it { is_expected.to belong_to(:envelope).class_name("Budget::Envelope") }

  it "uses the budget_assignments table" do
    expect(Budget::Assignment.table_name).to eq("budget_assignments")
  end

  describe "month" do
    it "is required" do
      assignment = build(:budget_assignment, month: nil)

      expect(assignment).not_to be_valid
      expect(assignment.errors.full_messages).to eq([ "Month can't be blank" ])
    end

    it "is normalized to the 1st of the month" do
      expect(Budget::Assignment.new(month: "2026-09-17").month).to eq(Date.new(2026, 9, 1))
      expect(Budget::Assignment.new(month: Date.new(2026, 9, 30)).month).to eq(Date.new(2026, 9, 1))
    end

    it "may be any month, in the past or the future" do
      expect(build(:budget_assignment, month: Date.new(1999, 12, 1))).to be_valid
      expect(build(:budget_assignment, month: Date.new(2099, 1, 1))).to be_valid
    end
  end

  describe "amount" do
    it "is a number above 0" do
      expect(build(:budget_assignment, amount: "0.01")).to be_valid

      [ "0", "-5" ].each do |amount|
        assignment = build(:budget_assignment, amount: amount)

        expect(assignment).not_to be_valid
        expect(assignment.errors.full_messages).to eq([ "Assigned must be greater than 0" ])
      end
    end

    it "accepts up to 2 decimal places" do
      assignment = build(:budget_assignment, amount: "1234.56")

      expect(assignment).to be_valid
      expect(assignment.amount).to eq(BigDecimal("1234.56"))
    end

    it "rejects more than 2 decimal places instead of rounding" do
      assignment = build(:budget_assignment, amount: "10.005")

      expect(assignment).not_to be_valid
      expect(assignment.errors.full_messages).to eq([ "Assigned can't have more than 2 decimal places" ])
    end

    it "accepts trailing zeros beyond 2 decimal places" do
      expect(build(:budget_assignment, amount: "10.500")).to be_valid
    end

    it "rejects something that isn't a number" do
      [ "$1,000", "", nil, "NaN", "Infinity" ].each do |amount|
        assignment = build(:budget_assignment, amount: amount)

        expect(assignment).not_to be_valid
        expect(assignment.errors.full_messages).to eq([ "Assigned is not a number" ])
      end
    end

    it "rejects an amount too large to store" do
      expect(build(:budget_assignment, amount: "10000000000000")).not_to be_valid
      expect(build(:budget_assignment, amount: "9999999999999.99")).to be_valid
    end
  end

  describe "#assign" do
    it "saves a positive amount, and is true" do
      assignment = build(:budget_assignment, amount: nil)

      expect(assignment.assign("250")).to be(true)
      expect(assignment).to be_persisted
      expect(assignment.reload.amount).to eq(250)
    end

    it "changes the amount of an Assignment that's saved already, and is true" do
      assignment = create(:budget_assignment, amount: 100)

      expect(assignment.assign("75.50")).to be(true)
      expect(assignment.reload.amount).to eq(BigDecimal("75.50"))
    end

    [ "", "0", "0.00" ].each do |nothing|
      it "deletes a saved Assignment for #{nothing.inspect}, which is to assign nothing, and is true" do
        assignment = create(:budget_assignment, amount: 100)

        expect(assignment.assign(nothing)).to be(true)
        expect(assignment).to be_destroyed
        expect(Budget::Assignment.exists?(assignment.id)).to be(false)
      end

      it "has nothing to delete for #{nothing.inspect} on one that was never saved, which is true too" do
        assignment = build(:budget_assignment)

        expect(assignment.assign(nothing)).to be(true)
        expect(assignment).not_to be_persisted
      end
    end

    it "is false for an amount that's refused, with the reasons in errors, and keeps what was saved" do
      assignment = create(:budget_assignment, amount: 100)

      expect(assignment.assign("-5")).to be(false)
      expect(assignment.errors.full_messages).to eq([ "Assigned must be greater than 0" ])
      expect(assignment.reload.amount).to eq(100)
    end
  end

  describe "one per envelope and month" do
    let!(:existing) { create(:budget_assignment, month: Date.new(2026, 9, 1)) }

    it "refuses a second Assignment for the same envelope and month, whichever day of the month it's given" do
      duplicate = build(:budget_assignment, envelope: existing.envelope, month: Date.new(2026, 9, 17))

      expect(duplicate).not_to be_valid
      expect(duplicate.errors.full_messages).to eq([ "Month has already been taken" ])
    end

    it "lets the envelope have another month, and another envelope the same month" do
      expect(build(:budget_assignment, envelope: existing.envelope, month: Date.new(2026, 10, 1))).to be_valid
      expect(build(:budget_assignment, month: Date.new(2026, 9, 1))).to be_valid
    end

    it "can be changed without clashing with itself" do
      expect(existing.update(amount: 5)).to be(true)
    end
  end

  describe "database constraints" do
    let(:assignment) { create(:budget_assignment, month: Date.new(2026, 9, 1), amount: 100) }

    # Plain SQL, because the model would normalize or reject most of these values before the database saw them.
    def update_assignment(assignments)
      Budget::Assignment.where(id: assignment.id).update_all(assignments)
    end

    it "rejects a second Assignment for the same envelope and month" do
      duplicate = Budget::Assignment.new(envelope: assignment.envelope, month: assignment.month, amount: 5)

      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "rejects a month that isn't the 1st" do
      expect { update_assignment("month = '2026-09-15'") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_assignments_month_first_of_month/)
    end

    it "rejects an amount of zero" do
      expect { update_assignment("amount = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_assignments_amount_positive/)
    end

    it "rejects a negative amount" do
      expect { update_assignment("amount = -0.01") }.to raise_error(ActiveRecord::CheckViolation, /budget_assignments_amount_positive/)
    end

    # One column per example: PostgreSQL aborts the spec's transaction at the first violation.
    %w[ envelope_id month amount ].each do |column|
      it "requires a #{column}" do
        expect { update_assignment("#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "needs an envelope that exists" do
      expect { update_assignment("envelope_id = 0") }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "keeps an envelope with Assignments from being deleted without them" do
      expect { Budget::Envelope.where(id: assignment.envelope_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
