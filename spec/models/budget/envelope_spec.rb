require "rails_helper"

RSpec.describe Budget::Envelope, type: :model do
  subject { build(:budget_envelope) }

  it { is_expected.to belong_to(:budget) }
  it { is_expected.to have_many(:assignments).class_name("Budget::Assignment").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:spends).class_name("Budget::Spend").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:refunds).class_name("Budget::Refund").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:outgoing_reallocations).class_name("Budget::EnvelopeReallocation").with_foreign_key(:from_envelope_id).dependent(:restrict_with_error) }
  it { is_expected.to have_many(:incoming_reallocations).class_name("Budget::EnvelopeReallocation").with_foreign_key(:to_envelope_id).dependent(:restrict_with_error) }
  it { is_expected.to validate_presence_of(:name) }

  it "uses the budget_envelopes table" do
    expect(Budget::Envelope.table_name).to eq("budget_envelopes")
  end

  describe "name" do
    it "squishes surrounding and repeated whitespace" do
      expect(Budget::Envelope.new(name: "  Rent \n and   bills ").name).to eq("Rent and bills")
    end

    it "must be unique within a budget, ignoring case and extra whitespace" do
      existing = create(:budget_envelope, name: "Groceries")
      envelope = build(:budget_envelope, budget: existing.budget, name: "  GROCERIES ")

      expect(envelope).not_to be_valid
      expect(envelope.errors.full_messages).to eq([ "Name has already been taken" ])
    end

    it "can repeat another budget's envelope name" do
      create(:budget_envelope, name: "Groceries")

      expect(build(:budget_envelope, name: "Groceries")).to be_valid
    end
  end

  describe "starting balance" do
    it "is 0 when left blank" do
      expect(build(:budget_envelope, starting_balance: "").starting_balance).to eq(0)
      expect(build(:budget_envelope, starting_balance: nil).starting_balance).to eq(0)
    end

    it "is 0 for a new envelope" do
      expect(Budget::Envelope.new.starting_balance).to eq(0)
    end

    it "may be negative" do
      expect(build(:budget_envelope, starting_balance: "-30.5")).to be_valid
    end

    it "accepts up to 2 decimal places" do
      envelope = build(:budget_envelope, starting_balance: "1234.56")

      expect(envelope).to be_valid
      expect(envelope.starting_balance).to eq(BigDecimal("1234.56"))
    end

    it "rejects more than 2 decimal places instead of rounding" do
      envelope = build(:budget_envelope, starting_balance: "10.005")

      expect(envelope).not_to be_valid
      expect(envelope.errors.full_messages).to eq([ "Starting balance can't have more than 2 decimal places" ])
    end

    it "accepts trailing zeros beyond 2 decimal places" do
      expect(build(:budget_envelope, starting_balance: "10.500")).to be_valid
    end

    it "rejects something that isn't a number" do
      envelope = build(:budget_envelope, starting_balance: "$1,000")

      expect(envelope).not_to be_valid
      expect(envelope.errors.full_messages).to eq([ "Starting balance is not a number" ])
    end

    it "rejects NaN and Infinity as not numbers, without also complaining about decimal places" do
      [ "NaN", "Infinity", "-Infinity" ].each do |value|
        envelope = build(:budget_envelope, starting_balance: value)

        expect(envelope).not_to be_valid
        expect(envelope.errors.full_messages).to eq([ "Starting balance is not a number" ])
      end
    end

    it "rejects an amount too large to store" do
      expect(build(:budget_envelope, starting_balance: "10000000000000")).not_to be_valid
      expect(build(:budget_envelope, starting_balance: "-10000000000000")).not_to be_valid
      expect(build(:budget_envelope, starting_balance: "9999999999999.99")).to be_valid
    end
  end

  describe ".alphabetical" do
    it "sorts by name, ignoring case" do
      budget = create(:budget)
      rent = create(:budget_envelope, budget: budget, name: "rent")
      bills = create(:budget_envelope, budget: budget, name: "Bills")
      groceries = create(:budget_envelope, budget: budget, name: "Groceries")

      expect(budget.envelopes.alphabetical).to eq([ bills, groceries, rent ])
    end
  end

  describe "#assign" do
    let(:envelope) { create(:budget_envelope) }
    let(:september) { Date.new(2026, 9, 1) }

    # What the envelope has assigned, as [ month, amount ] pairs, read from the database afresh.
    def assigned
      Budget::Assignment.where(envelope: envelope).order(:month).pluck(:month, :amount)
    end

    it "creates the month's Assignment from a positive amount, and returns it" do
      assignment = envelope.assign(september, "400.50")

      expect(assignment).to be_persisted
      expect(assignment.errors).to be_empty
      expect(assigned).to eq([ [ september, BigDecimal("400.50") ] ])
    end

    it "changes the month's Assignment rather than adding another" do
      existing = create(:budget_assignment, envelope: envelope, month: september, amount: 100)

      assignment = envelope.assign(september, "250")

      expect(assignment).to eq(existing)
      expect(assigned).to eq([ [ september, 250 ] ])
    end

    it "can assign again and again, the last amount being the one that counts" do
      envelope.assign(september, "100")
      envelope.assign(september, "100")
      envelope.assign(september, "75.25")

      expect(assigned).to eq([ [ september, BigDecimal("75.25") ] ])
    end

    it "takes any day of the month for the month" do
      envelope.assign(Date.new(2026, 9, 17), "10")
      envelope.assign(Date.new(2026, 9, 30), "20")

      expect(assigned).to eq([ [ september, 20 ] ])
    end

    [ "", " ", nil, "0", "0.00", "0.0", " 0 ", "-0" ].each do |nothing|
      it "deletes the month's Assignment for #{nothing.inspect}, which is to assign nothing" do
        create(:budget_assignment, envelope: envelope, month: september, amount: 100)

        assignment = envelope.assign(september, nothing)

        expect(assigned).to be_empty
        expect(assignment).to be_destroyed
        expect(assignment.errors).to be_empty
      end

      it "has nothing to delete for #{nothing.inspect} when nothing is assigned, and that's fine" do
        assignment = envelope.assign(september, nothing)

        expect(assigned).to be_empty
        expect(assignment).not_to be_persisted
        expect(assignment.errors).to be_empty
      end
    end

    {
      "-5" => "Assigned must be greater than 0",
      "-0.01" => "Assigned must be greater than 0",
      "10.005" => "Assigned can't have more than 2 decimal places",
      "10000000000000" => "Assigned must be less than 10000000000000",
      "abc" => "Assigned is not a number",
      "$1,000" => "Assigned is not a number",
      "NaN" => "Assigned is not a number"
    }.each do |refused, message|
      it "refuses #{refused.inspect} with the reason, keeps what was assigned, and keeps what was entered for the form" do
        create(:budget_assignment, envelope: envelope, month: september, amount: 100)

        assignment = envelope.assign(september, refused)

        expect(assignment.errors.full_messages).to eq([ message ])
        expect(assignment.amount_before_type_cast).to eq(refused)
        expect(assigned).to eq([ [ september, 100 ] ])
      end
    end

    it "creates nothing when the amount for a month with no Assignment is refused" do
      assignment = envelope.assign(september, "-5")

      expect(assignment).not_to be_persisted
      expect(assigned).to be_empty
    end

    it "touches only that envelope's Assignment for that month" do
      other_month = create(:budget_assignment, envelope: envelope, month: Date.new(2026, 10, 1), amount: 7)
      other_envelope = create(:budget_assignment, month: september, amount: 9)

      envelope.assign(september, "100")
      envelope.assign(september, "")

      expect(other_month.reload.amount).to eq(7)
      expect(other_envelope.reload.amount).to eq(9)
    end
  end

  describe "deleting" do
    it "is refused while the envelope has records, with the reason, and keeps both the envelope and its records" do
      assignment = create(:budget_assignment)
      envelope = assignment.envelope

      expect(envelope.destroy).to be(false)

      expect(envelope.errors.full_messages).to eq([ "This envelope can't be deleted because it has records." ])
      expect(Budget::Envelope.exists?(envelope.id)).to be(true)
      expect(Budget::Assignment.exists?(assignment.id)).to be(true)
    end

    it "is refused while the envelope has Spends, with the same reason, and keeps both" do
      spend = create(:budget_spend)
      envelope = spend.envelope

      expect(envelope.destroy).to be(false)

      expect(envelope.errors.full_messages).to eq([ "This envelope can't be deleted because it has records." ])
      expect(Budget::Envelope.exists?(envelope.id)).to be(true)
      expect(Budget::Spend.exists?(spend.id)).to be(true)
    end

    it "is refused while the envelope has Refunds, with the same reason, and keeps both" do
      refund = create(:budget_refund)
      envelope = refund.envelope

      expect(envelope.destroy).to be(false)

      expect(envelope.errors.full_messages).to eq([ "This envelope can't be deleted because it has records." ])
      expect(Budget::Envelope.exists?(envelope.id)).to be(true)
      expect(Budget::Refund.exists?(refund.id)).to be(true)
    end

    it "is refused while the envelope has Reallocations out of it, with the same reason, and keeps both" do
      reallocation = create(:budget_envelope_reallocation)
      envelope = reallocation.from_envelope

      expect(envelope.destroy).to be(false)

      expect(envelope.errors.full_messages).to eq([ "This envelope can't be deleted because it has records." ])
      expect(Budget::Envelope.exists?(envelope.id)).to be(true)
      expect(Budget::EnvelopeReallocation.exists?(reallocation.id)).to be(true)
    end

    it "is refused while the envelope has Reallocations into it, with the same reason, and keeps both" do
      reallocation = create(:budget_envelope_reallocation)
      envelope = reallocation.to_envelope

      expect(envelope.destroy).to be(false)

      expect(envelope.errors.full_messages).to eq([ "This envelope can't be deleted because it has records." ])
      expect(Budget::Envelope.exists?(envelope.id)).to be(true)
      expect(Budget::EnvelopeReallocation.exists?(reallocation.id)).to be(true)
    end

    it "is allowed once the records are gone" do
      assignment = create(:budget_assignment)
      assignment.destroy!

      expect(assignment.envelope.destroy).to be_truthy
      expect(Budget::Envelope.exists?(assignment.envelope_id)).to be(false)
    end

    it "is allowed once its Spends are gone" do
      spend = create(:budget_spend)
      spend.destroy!

      expect(spend.envelope.destroy).to be_truthy
      expect(Budget::Envelope.exists?(spend.envelope_id)).to be(false)
    end

    it "is allowed for an envelope with nothing recorded against it, whatever its Starting balance" do
      envelope = create(:budget_envelope, starting_balance: 250)

      expect(envelope.destroy).to be_truthy
    end
  end

  describe "database constraints" do
    let(:envelope) { create(:budget_envelope, name: "Groceries") }

    it "rejects a blank name" do
      expect { Budget::Envelope.where(id: envelope.id).update_all(name: "   ") }
        .to raise_error(ActiveRecord::CheckViolation)
    end

    it "rejects a name already used in the budget, ignoring case" do
      duplicate = Budget::Envelope.new(budget: envelope.budget, name: "GROCERIES")

      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "requires a starting balance" do
      expect { Budget::Envelope.where(id: envelope.id).update_all(starting_balance: nil) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end

    it "keeps a budget with envelopes from being deleted without them" do
      expect { Budget.where(id: envelope.budget_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
