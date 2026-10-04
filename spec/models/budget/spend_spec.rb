require "rails_helper"

RSpec.describe Budget::Spend, type: :model do
  subject { build(:budget_spend) }

  it { is_expected.to belong_to(:envelope).class_name("Budget::Envelope") }

  it "uses the budget_spends table" do
    expect(Budget::Spend.table_name).to eq("budget_spends")
  end

  it "has no budget of its own: it's in the budget of its envelope" do
    expect(Budget::Spend.column_names).not_to include("budget_id")
  end

  describe "envelope" do
    it "is required" do
      spend = build(:budget_spend, envelope: nil)

      expect(spend).not_to be_valid
      expect(spend.errors.full_messages).to eq([ "Envelope can't be blank" ])
    end
  end

  describe "description" do
    it { is_expected.to validate_presence_of(:description) }

    it "squishes surrounding and repeated whitespace" do
      expect(Budget::Spend.new(description: "  Lob \n laws  ").description).to eq("Lob laws")
    end

    it "can't be only whitespace" do
      spend = build(:budget_spend, description: " \n ")

      expect(spend).not_to be_valid
      expect(spend.errors.full_messages).to eq([ "Description can't be blank" ])
    end
  end

  describe "date" do
    it "is required" do
      spend = build(:budget_spend, date: nil)

      expect(spend).not_to be_valid
      expect(spend.errors.full_messages).to eq([ "Date can't be blank" ])
    end

    it "may be any date, in the past or the future" do
      expect(build(:budget_spend, date: Date.new(1999, 12, 31))).to be_valid
      expect(build(:budget_spend, date: Date.new(2099, 1, 1))).to be_valid
    end
  end

  describe "amount" do
    it "is a number above 0" do
      expect(build(:budget_spend, amount: "0.01")).to be_valid

      [ "0", "-5" ].each do |amount|
        spend = build(:budget_spend, amount: amount)

        expect(spend).not_to be_valid
        expect(spend.errors.full_messages).to eq([ "Amount must be greater than 0" ])
      end
    end

    it "accepts up to 2 decimal places" do
      spend = build(:budget_spend, amount: "1234.56")

      expect(spend).to be_valid
      expect(spend.amount).to eq(BigDecimal("1234.56"))
    end

    it "rejects more than 2 decimal places instead of rounding" do
      spend = build(:budget_spend, amount: "10.005")

      expect(spend).not_to be_valid
      expect(spend.errors.full_messages).to eq([ "Amount can't have more than 2 decimal places" ])
    end

    it "accepts trailing zeros beyond 2 decimal places" do
      expect(build(:budget_spend, amount: "10.500")).to be_valid
    end

    it "rejects something that isn't a number" do
      [ "$1,000", "", nil, "NaN", "Infinity" ].each do |amount|
        spend = build(:budget_spend, amount: amount)

        expect(spend).not_to be_valid
        expect(spend.errors.full_messages).to eq([ "Amount is not a number" ])
      end
    end

    it "rejects an amount too large to store" do
      expect(build(:budget_spend, amount: "10000000000000")).not_to be_valid
      expect(build(:budget_spend, amount: "9999999999999.99")).to be_valid
    end
  end

  describe "notes" do
    it "are saved as an empty string when left blank" do
      expect(create(:budget_spend, notes: nil).reload.notes).to eq("")
      expect(create(:budget_spend, notes: " \n ").reload.notes).to eq("")
    end

    it "keep their text, without the whitespace around it" do
      spend = build(:budget_spend, notes: "  Costco run\nsplit with Household \n")

      expect(spend.notes).to eq("Costco run\nsplit with Household")
    end
  end

  describe ".dated_in" do
    let(:envelope) { create(:budget_envelope) }

    it "lists the Spends dated in the month, whichever day of it is asked about, from its first day to its last" do
      first_day = create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 1))
      last_day = create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 30))
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 8, 31))
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 10, 1))

      expect(envelope.spends.dated_in(Date.new(2026, 9, 17))).to contain_exactly(first_day, last_day)
    end

    it "finds the months at either end of a year" do
      december = create(:budget_spend, envelope: envelope, date: Date.new(2026, 12, 31))
      january = create(:budget_spend, envelope: envelope, date: Date.new(2027, 1, 1))

      expect(envelope.spends.dated_in(Date.new(2026, 12, 1))).to contain_exactly(december)
      expect(envelope.spends.dated_in(Date.new(2027, 1, 1))).to contain_exactly(january)
    end
  end

  describe ".newest_first" do
    it "puts the latest date first, and the most recently entered first within a date" do
      envelope = create(:budget_envelope)
      earlier_date = create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 1))
      entered_second = create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 30), created_at: Time.zone.local(2026, 9, 30, 12))
      # Saved after the other two, but entered earlier than either.
      entered_first = create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 30), created_at: Time.zone.local(2026, 9, 30, 8))

      expect(envelope.spends.newest_first).to eq([ entered_second, entered_first, earlier_date ])
    end
  end

  describe "database constraints" do
    let(:spend) { create(:budget_spend, description: "Loblaws", date: Date.new(2026, 9, 15), amount: 100) }

    # Plain SQL, because the model would normalize or reject most of these values before the database saw them.
    def update_spend(assignments)
      Budget::Spend.where(id: spend.id).update_all(assignments)
    end

    it "rejects a blank description" do
      expect { update_spend("description = '   '") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_spends_description_not_blank/)
    end

    it "rejects an amount of zero" do
      expect { update_spend("amount = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_spends_amount_positive/)
    end

    it "rejects a negative amount" do
      expect { update_spend("amount = -0.01") }.to raise_error(ActiveRecord::CheckViolation, /budget_spends_amount_positive/)
    end

    it "requires notes, which are empty rather than null" do
      expect { update_spend("notes = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      expect(Budget::Spend.new.notes).to eq("")
    end

    # One column per example: PostgreSQL aborts the spec's transaction at the first violation.
    %w[ envelope_id description date amount ].each do |column|
      it "requires a #{column}" do
        expect { update_spend("#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "keeps an envelope with Spends from being deleted without them" do
      expect { Budget::Envelope.where(id: spend.envelope_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
