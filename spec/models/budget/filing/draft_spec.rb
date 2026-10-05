require "rails_helper"

RSpec.describe Budget::Filing::Draft do
  let(:bank_transaction) { create(:budget_bank_transaction, description: "COSTCO #123", date: Date.new(2026, 9, 12), amount: -100) }

  describe "#edited_from?" do
    it "isn't for a draft that starts as the bank transaction does, whatever its kind and envelope" do
      expect(described_class.for(bank_transaction)).not_to be_edited_from(bank_transaction)
      expect(described_class.for(bank_transaction, kind: "refund", envelope_id: 7)).not_to be_edited_from(bank_transaction)
    end

    it "isn't for what a form sent back as the bank's own, as strings" do
      draft = described_class.new(kind: "spend", description: "COSTCO #123", date: "2026-09-12", amount: "100", notes: "", month: "2026-09-01")

      expect(draft).not_to be_edited_from(bank_transaction)
    end

    {
      "description" => { description: "Costco run" },
      "date" => { date: "2026-09-13" },
      "amount" => { amount: "90" },
      "an amount that isn't a figure" => { amount: "lots" },
      "no amount" => { amount: nil },
      "notes" => { notes: "Bulk buy" },
      "a month that isn't the date's" => { month: "2026-10-01" }
    }.each do |what, attributes|
      it "is for #{what}" do
        expect(described_class.for(bank_transaction, **attributes)).to be_edited_from(bank_transaction)
      end
    end
  end
end
