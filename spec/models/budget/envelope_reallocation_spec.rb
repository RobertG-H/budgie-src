require "rails_helper"

RSpec.describe Budget::EnvelopeReallocation, type: :model do
  subject { build(:budget_envelope_reallocation) }

  it { is_expected.to belong_to(:from_envelope).class_name("Budget::Envelope") }
  it { is_expected.to belong_to(:to_envelope).class_name("Budget::Envelope") }

  it "uses the budget_envelope_reallocations table" do
    expect(Budget::EnvelopeReallocation.table_name).to eq("budget_envelope_reallocations")
  end

  it "has no budget of its own: it's in the budget of its From envelope" do
    expect(Budget::EnvelopeReallocation.column_names).not_to include("budget_id")
  end

  describe "envelopes" do
    it "need a From envelope" do
      reallocation = build(:budget_envelope_reallocation, from_envelope: nil, to_envelope: create(:budget_envelope))

      expect(reallocation).not_to be_valid
      expect(reallocation.errors.full_messages).to eq([ "From can't be blank" ])
    end

    it "need a To envelope" do
      reallocation = build(:budget_envelope_reallocation, to_envelope: nil)

      expect(reallocation).not_to be_valid
      expect(reallocation.errors.full_messages).to eq([ "To can't be blank" ])
    end

    it "can't be the same envelope" do
      envelope = create(:budget_envelope)
      reallocation = build(:budget_envelope_reallocation, from_envelope: envelope, to_envelope: envelope)

      expect(reallocation).not_to be_valid
      expect(reallocation.errors.full_messages).to eq([ "To can't be the same envelope as From" ])
    end

    it "must be in the same budget" do
      reallocation = build(:budget_envelope_reallocation, from_envelope: create(:budget_envelope), to_envelope: create(:budget_envelope))

      expect(reallocation).not_to be_valid
      expect(reallocation.errors.full_messages).to eq([ "To must be in the same budget as From" ])
    end

    it "are two envelopes of one budget when valid" do
      budget = create(:budget)
      reallocation = build(:budget_envelope_reallocation,
        from_envelope: create(:budget_envelope, budget: budget), to_envelope: create(:budget_envelope, budget: budget))

      expect(reallocation).to be_valid
    end
  end

  describe "description" do
    it { is_expected.to validate_presence_of(:description) }

    it "squishes surrounding and repeated whitespace" do
      expect(Budget::EnvelopeReallocation.new(description: "  Covering \n the dentist  ").description).to eq("Covering the dentist")
    end

    it "can't be only whitespace" do
      reallocation = build(:budget_envelope_reallocation, description: " \n ")

      expect(reallocation).not_to be_valid
      expect(reallocation.errors.full_messages).to eq([ "Description can't be blank" ])
    end
  end

  describe "date" do
    it "is required" do
      reallocation = build(:budget_envelope_reallocation, date: nil)

      expect(reallocation).not_to be_valid
      expect(reallocation.errors.full_messages).to eq([ "Date can't be blank" ])
    end

    it "may be any date, in the past or the future" do
      expect(build(:budget_envelope_reallocation, date: Date.new(1999, 12, 31))).to be_valid
      expect(build(:budget_envelope_reallocation, date: Date.new(2099, 1, 1))).to be_valid
    end
  end

  describe "amount" do
    it "is a number above 0" do
      expect(build(:budget_envelope_reallocation, amount: "0.01")).to be_valid

      [ "0", "-5" ].each do |amount|
        reallocation = build(:budget_envelope_reallocation, amount: amount)

        expect(reallocation).not_to be_valid
        expect(reallocation.errors.full_messages).to eq([ "Amount must be greater than 0" ])
      end
    end

    it "rejects more than 2 decimal places instead of rounding" do
      reallocation = build(:budget_envelope_reallocation, amount: "10.005")

      expect(reallocation).not_to be_valid
      expect(reallocation.errors.full_messages).to eq([ "Amount can't have more than 2 decimal places" ])
    end

    it "rejects something that isn't a number" do
      [ "$1,000", "", nil, "NaN", "Infinity" ].each do |amount|
        reallocation = build(:budget_envelope_reallocation, amount: amount)

        expect(reallocation).not_to be_valid
        expect(reallocation.errors.full_messages).to eq([ "Amount is not a number" ])
      end
    end

    it "rejects an amount too large to store" do
      expect(build(:budget_envelope_reallocation, amount: "10000000000000")).not_to be_valid
      expect(build(:budget_envelope_reallocation, amount: "9999999999999.99")).to be_valid
    end

    it "may be more than the From envelope has Available: it can leave that envelope Overspent" do
      reallocation = create(:budget_envelope_reallocation, amount: 5000)

      expect(reallocation.from_envelope.starting_balance).to eq(0)
      expect(reallocation).to be_persisted
    end
  end

  describe "notes" do
    it "are saved as an empty string when left blank" do
      expect(create(:budget_envelope_reallocation, notes: nil).reload.notes).to eq("")
      expect(create(:budget_envelope_reallocation, notes: " \n ").reload.notes).to eq("")
    end
  end

  describe ".dated_in" do
    it "lists the Reallocations dated in the month, from its first day to its last" do
      from = create(:budget_envelope)
      to = create(:budget_envelope, budget: from.budget)
      first_day = create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: Date.new(2026, 9, 1))
      last_day = create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: Date.new(2026, 9, 30))
      create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: Date.new(2026, 8, 31))
      create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: Date.new(2026, 10, 1))

      expect(from.outgoing_reallocations.dated_in(Date.new(2026, 9, 17))).to contain_exactly(first_day, last_day)
    end
  end

  describe ".newest_first" do
    it "puts the latest date first, and the most recently entered first within a date" do
      from = create(:budget_envelope)
      to = create(:budget_envelope, budget: from.budget)
      earlier_date = create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: Date.new(2026, 9, 1))
      entered_second = create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: Date.new(2026, 9, 30), created_at: Time.zone.local(2026, 9, 30, 12))
      entered_first = create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: Date.new(2026, 9, 30), created_at: Time.zone.local(2026, 9, 30, 8))

      expect(from.outgoing_reallocations.newest_first).to eq([ entered_second, entered_first, earlier_date ])
    end
  end

  describe "database constraints" do
    let(:reallocation) { create(:budget_envelope_reallocation, description: "Covering the dentist") }

    # Plain SQL, because the model would normalize or reject most of these values before the database saw them.
    def update_reallocation(assignments)
      Budget::EnvelopeReallocation.where(id: reallocation.id).update_all(assignments)
    end

    it "rejects a blank description" do
      expect { update_reallocation("description = '   '") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_envelope_reallocations_description_not_blank/)
    end

    it "rejects an amount of zero" do
      expect { update_reallocation("amount = 0") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_envelope_reallocations_amount_positive/)
    end

    it "rejects a negative amount" do
      expect { update_reallocation("amount = -0.01") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_envelope_reallocations_amount_positive/)
    end

    it "requires notes, which are empty rather than null" do
      expect { update_reallocation("notes = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      expect(Budget::EnvelopeReallocation.new.notes).to eq("")
    end

    it "rejects the same envelope on both sides" do
      expect { update_reallocation("to_envelope_id = from_envelope_id") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_envelope_reallocations_envelopes_differ/)
    end

    # One column per example: PostgreSQL aborts the spec's transaction at the first violation.
    %w[ from_envelope_id to_envelope_id description date amount ].each do |column|
      it "requires a #{column}" do
        expect { update_reallocation("#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "keeps an envelope with Reallocations out of it from being deleted without them" do
      expect { Budget::Envelope.where(id: reallocation.from_envelope_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end

    it "keeps an envelope with Reallocations into it from being deleted without them" do
      expect { Budget::Envelope.where(id: reallocation.to_envelope_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
