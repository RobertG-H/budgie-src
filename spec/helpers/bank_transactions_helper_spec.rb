require "rails_helper"

RSpec.describe BankTransactionsHelper, type: :helper do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:bank_transaction) { create(:budget_bank_transaction, account: create(:budget_account, budget: budget), description: "LOBLAWS #1234", date: Date.new(2026, 10, 3), amount: -82.45) }

  describe "#filing_details_open?" do
    def open?(*drafts)
      helper.filing_details_open?(Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: drafts), drafts.first)
    end

    it "is closed for a record that starts as the bank transaction does" do
      expect(open?(Budget::Filing::Draft.for(bank_transaction))).to be(false)
    end

    it "is open for each record of a split" do
      expect(open?(Budget::Filing::Draft.for(bank_transaction, amount: 40), Budget::Filing::Draft.for(bank_transaction, amount: 42.45))).to be(true)
    end

    %i[ description date amount month notes ].each do |field|
      it "is open for an error on the #{field}" do
        draft = Budget::Filing::Draft.for(bank_transaction).tap { |d| d.errors.add(field, "is wrong") }

        expect(open?(draft)).to be(true)
      end
    end

    it "is closed for an error on the envelope or the kind, which aren't in it" do
      draft = Budget::Filing::Draft.for(bank_transaction).tap { |d| d.errors.add(:envelope_id, "can't be blank") && d.errors.add(:kind, "is wrong") }

      expect(open?(draft)).to be(false)
    end
  end

  describe "#filing_details_summary" do
    # The date is spelled out by the helper that spells every date, which the views have with the rest.
    before { helper.extend(CsvFormatsHelper) }

    it "is the description, the date and the amount, which is as the bank has it to start with" do
      expect(helper.filing_details_summary(Budget::Filing::Draft.for(bank_transaction), budget)).to eq("LOBLAWS #1234 · Oct 3, 2026 · $82.45")
    end

    it "leaves out what isn't there yet or isn't a figure" do
      draft = Budget::Filing::Draft.for(bank_transaction, description: " ", amount: "lots")

      expect(helper.filing_details_summary(draft, budget)).to eq("Oct 3, 2026")
    end

    it "says which month a Deposit counts toward when it isn't its date's, with the year only when that's another" do
      deposit = Budget::Filing::Draft.for(bank_transaction, kind: "deposit", date: Date.new(2026, 10, 3), month: Date.new(2026, 11, 1))
      december = Budget::Filing::Draft.for(bank_transaction, kind: "deposit", date: Date.new(2026, 12, 30), month: Date.new(2027, 1, 1))
      same = Budget::Filing::Draft.for(bank_transaction, kind: "deposit", date: Date.new(2026, 10, 3), month: Date.new(2026, 10, 1))

      expect(helper.filing_details_summary(deposit, budget)).to eq("LOBLAWS #1234 · Oct 3, 2026 · $82.45, counts toward November")
      expect(helper.filing_details_summary(december, budget)).to end_with(", counts toward January 2027")
      expect(helper.filing_details_summary(same, budget)).not_to include("counts toward")
    end
  end
end
