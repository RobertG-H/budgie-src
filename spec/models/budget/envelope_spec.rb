require "rails_helper"

RSpec.describe Budget::Envelope, type: :model do
  subject { build(:budget_envelope) }

  it { is_expected.to belong_to(:budget) }
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
