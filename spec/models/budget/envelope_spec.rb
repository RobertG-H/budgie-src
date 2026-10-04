require "rails_helper"

RSpec.describe Budget::Envelope, type: :model do
  subject { build(:budget_envelope) }

  it { is_expected.to belong_to(:budget) }
  it { is_expected.to have_many(:assignments).class_name("Budget::Assignment").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:spends).class_name("Budget::Spend").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:refunds).class_name("Budget::Refund").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:outgoing_reallocations).class_name("Budget::EnvelopeReallocation").with_foreign_key(:from_envelope_id).dependent(:restrict_with_error) }
  it { is_expected.to have_many(:ready_to_assign_reallocations).class_name("Budget::ReadyToAssignReallocation").dependent(:restrict_with_error) }
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

  describe "archiving" do
    let(:budget) { create(:budget, currency: "CAD") }
    let(:envelope) { create(:budget_envelope, budget: budget, name: "Gym") }
    let(:other) { create(:budget_envelope, budget: budget, name: "Other") }
    let(:message_for_later) { "It has Assigned, Spends, Refunds or Reallocations after October 2026. Clear them first." }

    # Today is in October 2026.
    around { |example| travel_to(Time.zone.local(2026, 10, 15, 12)) { example.run } }

    it "is null while the envelope is in use, and has no default" do
      expect(Budget::Envelope.new.archived_at).to be_nil
      expect(Budget::Envelope.columns_hash["archived_at"]).to have_attributes(null: true, default: nil)
    end

    it "has the scopes active and archived, and archived? to tell them apart" do
      archived = create(:budget_envelope, budget: budget, archived_at: Time.current)
      envelope

      expect(budget.envelopes.active).to contain_exactly(envelope)
      expect(budget.envelopes.archived).to contain_exactly(archived)
      expect(archived).to be_archived
      expect(envelope).not_to be_archived
    end

    describe "#archive!" do
      it "archives an envelope whose Available is 0 and that has nothing dated after the month" do
        envelope.archive!

        expect(envelope.reload).to be_archived
        expect(envelope.archived_at).to be_within(1.second).of(Time.current)
      end

      it "archives an envelope with history, as long as it nets to 0 now" do
        create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 40)
        create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 20), amount: 40)
        create(:budget_assignment, envelope: envelope, month: Date.new(2026, 10, 1), amount: 25)
        create(:budget_refund, envelope: envelope, date: Date.new(2026, 10, 3), amount: 5)
        create(:budget_envelope_reallocation, from_envelope: envelope, to_envelope: other, date: Date.new(2026, 10, 9), amount: 30)

        envelope.archive!

        expect(envelope.reload).to be_archived
      end

      it "is refused with Available above 0, saying how much and what to do, and changes nothing" do
        create(:budget_assignment, envelope: envelope, month: Date.new(2026, 10, 1), amount: 12)

        expect { envelope.archive! }.to raise_error(
          Budget::Envelope::Refused, "Available is $12.00 in October 2026. Lower this month's Assigned, spend it or reallocate it first."
        )
        expect(envelope.reload).not_to be_archived
      end

      it "is refused with Available below 0, saying how much and what to do, and changes nothing" do
        create(:budget_spend, envelope: envelope, date: Date.new(2026, 10, 2), amount: 12)

        expect { envelope.archive! }.to raise_error(
          Budget::Envelope::Refused, "Available is -$12.00 in October 2026. Assign more to it or reallocate money to it first."
        )
        expect(envelope.reload).not_to be_archived
      end

      it "counts its Starting balance in Available" do
        envelope.update!(starting_balance: 12)

        expect { envelope.archive! }.to raise_error(Budget::Envelope::Refused, /\AAvailable is \$12.00 in October 2026/)
      end

      it "is refused with Assigned entered ahead for a later month" do
        create(:budget_assignment, envelope: envelope, month: Date.new(2026, 11, 1), amount: 10)

        expect { envelope.archive! }.to raise_error(Budget::Envelope::Refused, message_for_later)
        expect(envelope.reload).not_to be_archived
      end

      {
        "a Spend" => -> { create(:budget_spend, envelope: envelope, date: Date.new(2026, 11, 1), amount: 10) },
        "a Refund" => -> { create(:budget_refund, envelope: envelope, date: Date.new(2026, 11, 1), amount: 10) },
        "a Reallocation out of it" => -> { create(:budget_envelope_reallocation, from_envelope: envelope, to_envelope: other, date: Date.new(2026, 11, 1), amount: 10) },
        "a Reallocation into it" => -> { create(:budget_envelope_reallocation, from_envelope: other, to_envelope: envelope, date: Date.new(2026, 11, 1), amount: 10) },
        "a Reallocation to Ready to Assign" => -> { create(:budget_ready_to_assign_reallocation, envelope: envelope, date: Date.new(2026, 11, 1), amount: 10) }
      }.each do |record, create_it|
        it "is refused with #{record} dated next month" do
          instance_exec(&create_it)

          expect { envelope.archive! }.to raise_error(Budget::Envelope::Refused, message_for_later)
          expect(envelope.reload).not_to be_archived
        end
      end

      it "allows a record dated on the last day of this month" do
        create(:budget_spend, envelope: envelope, date: Date.new(2026, 10, 31), amount: 10)
        create(:budget_refund, envelope: envelope, date: Date.new(2026, 10, 31), amount: 10)

        envelope.archive!

        expect(envelope.reload).to be_archived
      end

      it "is judged as of today whichever month it's asked for in: it takes no month" do
        create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 40)
        create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 20), amount: 25)

        expect { envelope.archive! }.to raise_error(Budget::Envelope::Refused, /\AAvailable is \$15.00 in October 2026/)
      end

      it "changes nothing for an envelope that's already archived, even one that would be refused now" do
        archived_at = Time.zone.local(2026, 6, 1)
        create(:budget_spend, envelope: envelope, date: Date.new(2026, 11, 1), amount: 10)
        envelope.update!(archived_at: archived_at)

        expect { envelope.archive! }.not_to raise_error

        expect(envelope.reload.archived_at).to eq(archived_at)
      end

      it "sees an envelope archived by someone else since it was loaded" do
        archived_at = Time.zone.local(2026, 6, 1)
        stale = Budget::Envelope.find(envelope.id)
        Budget::Envelope.where(id: envelope.id).update_all(archived_at: archived_at)

        stale.archive!

        expect(stale.reload.archived_at).to eq(archived_at)
      end

      it "runs inside the budget's row lock, as starting a new month does" do
        locked = nil
        allow(envelope.budget).to receive(:with_lock).and_wrap_original do |original, *args, &block|
          original.call(*args) { locked = true; block.call }
        end

        envelope.archive!

        expect(locked).to be(true)
      end
    end

    describe "#unarchive" do
      it "clears archived_at, and gives the envelope no Assigned" do
        envelope.archive!

        envelope.unarchive

        expect(envelope.reload).not_to be_archived
        expect(envelope.archived_at).to be_nil
        expect(envelope.assignments).to be_empty
      end

      it "has no precondition, and does nothing to an envelope in use" do
        create(:budget_spend, envelope: envelope, date: Date.new(2026, 11, 1), amount: 10)
        envelope.update!(archived_at: Time.current)

        envelope.unarchive

        expect(envelope.reload).not_to be_archived
        expect { envelope.unarchive }.not_to raise_error
      end
    end

    describe "its name" do
      it "stays reserved while it's archived, and the error says it's an archived envelope" do
        create(:budget_envelope, budget: budget, name: "Car", archived_at: Time.current)

        duplicate = build(:budget_envelope, budget: budget, name: " car ")

        expect(duplicate).not_to be_valid
        expect(duplicate.errors.full_messages).to eq([ "Name is already used by an archived envelope. Unarchive it or choose another name." ])
      end

      it "is taken, in the ordinary way, by an envelope in use" do
        create(:budget_envelope, budget: budget, name: "Car")

        duplicate = build(:budget_envelope, budget: budget, name: "Car")

        expect(duplicate.tap(&:valid?).errors.full_messages).to eq([ "Name has already been taken" ])
      end

      it "can still be another budget's" do
        create(:budget_envelope, name: "Car", archived_at: Time.current)

        expect(build(:budget_envelope, name: "Car")).to be_valid
      end

      it "doesn't clash with its own archived envelope: an archived envelope can be renamed and still be saved" do
        archived = create(:budget_envelope, budget: budget, name: "Car", archived_at: Time.current)

        expect(archived.update(name: "Old car", starting_balance: 5)).to be(true)
      end

      it "can't be an archived envelope's when an archived envelope is renamed to it" do
        create(:budget_envelope, budget: budget, name: "Car", archived_at: Time.current)
        archived = create(:budget_envelope, budget: budget, name: "Bike", archived_at: Time.current)

        expect(archived.update(name: "Car")).to be(false)
      end
    end

    describe "its Assigned" do
      let(:september) { Date.new(2026, 9, 1) }

      before do
        create(:budget_assignment, envelope: envelope, month: september, amount: 40)
        create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 20), amount: 40)
        envelope.archive!
      end

      def assigned
        Budget::Assignment.where(envelope: envelope).order(:month).pluck(:month, :amount)
      end

      it "can't be given a new amount in any month, and the error says the envelope is archived" do
        assignment = envelope.assign(Date.new(2026, 8, 1), "10")

        expect(assignment.errors.full_messages).to eq([ "Gym is archived, so its Assigned can't be changed. Unarchive it first." ])
        expect(assigned).to eq([ [ september, 40 ] ])
      end

      it "can't be changed, in a past month or this one" do
        [ september, Date.new(2026, 10, 1) ].each do |month|
          assignment = envelope.assign(month, "75")

          expect(assignment.errors.full_messages).to eq([ "Gym is archived, so its Assigned can't be changed. Unarchive it first." ])
        end
        expect(assigned).to eq([ [ september, 40 ] ])
      end

      [ "", "0" ].each do |nothing|
        it "can't be cleared with #{nothing.inspect}" do
          assignment = envelope.assign(september, nothing)

          expect(assignment.errors.full_messages).to eq([ "Gym is archived, so its Assigned can't be changed. Unarchive it first." ])
          expect(assigned).to eq([ [ september, 40 ] ])
        end
      end

      it "can be changed again once the envelope is unarchived" do
        envelope.unarchive

        assignment = envelope.assign(september, "75")

        expect(assignment.errors).to be_empty
        expect(assigned).to eq([ [ september, 75 ] ])
      end
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

    it "is refused while the envelope has Reallocations to Ready to Assign, with the same reason, and keeps both" do
      reallocation = create(:budget_ready_to_assign_reallocation)
      envelope = reallocation.envelope

      expect(envelope.destroy).to be(false)

      expect(envelope.errors.full_messages).to eq([ "This envelope can't be deleted because it has records." ])
      expect(Budget::Envelope.exists?(envelope.id)).to be(true)
      expect(Budget::ReadyToAssignReallocation.exists?(reallocation.id)).to be(true)
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

    it "takes its Filing rules with it, since an envelope with no records has nothing for them to file into, and leaves the others" do
      envelope = create(:budget_envelope)
      create(:budget_filing_rule, budget: envelope.budget, envelope: envelope, text: "loblaws")
      create(:budget_filing_rule, budget: envelope.budget, envelope: envelope, text: "costco")
      other = create(:budget_filing_rule, budget: envelope.budget, text: "shell")
      ignore = create(:budget_filing_rule, :ignore, budget: envelope.budget, text: "payment thank you")

      expect { envelope.destroy! }.to change(Budget::FilingRule, :count).by(-2)

      expect(Budget::FilingRule.all).to contain_exactly(other, ignore)
    end

    it "leaves the bank transactions its rules filed as they are, with no rule to say which one did it" do
      envelope = create(:budget_envelope)
      rule = create(:budget_filing_rule, budget: envelope.budget, envelope: envelope, text: "loblaws")
      bank_transaction = create(:budget_bank_transaction, :ignored, account: create(:budget_account, budget: envelope.budget))
      bank_transaction.update_columns(filing_rule_id: rule.id)

      envelope.destroy!

      expect(bank_transaction.reload).to be_ignored
      expect(bank_transaction.filing_rule_id).to be_nil
    end

    it "keeps its Filing rules when it's refused for having records" do
      assignment = create(:budget_assignment)
      rule = create(:budget_filing_rule, budget: assignment.envelope.budget, envelope: assignment.envelope)

      expect(assignment.envelope.destroy).to be(false)

      expect(Budget::FilingRule.exists?(rule.id)).to be(true)
    end

    it "doesn't have archiving blocked by its Filing rules, which go inactive and come back on unarchive" do
      envelope = create(:budget_envelope)
      rule = create(:budget_filing_rule, budget: envelope.budget, envelope: envelope)

      envelope.archive!

      expect(rule.reload).to be_inactive
      expect(Budget::FilingRule.active).to be_empty

      envelope.unarchive

      expect(rule.reload).not_to be_inactive
      expect(Budget::FilingRule.active).to contain_exactly(rule)
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
