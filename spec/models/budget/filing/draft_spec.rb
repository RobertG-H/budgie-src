require "rails_helper"

RSpec.describe Budget::Filing::Draft do
  let(:bank_transaction) { create(:budget_bank_transaction, description: "COSTCO #123", date: Date.new(2026, 9, 12), amount: -100) }

  describe ".for, which says what kind of record a bank transaction starts as" do
    let(:splitwise_account) { create(:budget_account, :synced) }

    it "is a Spend for money out, and a Deposit for a bank's money in, as it always was" do
      expect(described_class.for(bank_transaction).kind).to eq("spend")
      expect(described_class.for(create(:budget_bank_transaction, amount: 3000)).kind).to eq("deposit")
    end

    it "is a Refund for money in from Splitwise, since it's almost always friends paying back a share" do
      expect(described_class.for(create(:budget_bank_transaction, account: splitwise_account, amount: 50)).kind).to eq("refund")
    end

    it "is still a Spend for money out from Splitwise" do
      expect(described_class.for(create(:budget_bank_transaction, account: splitwise_account, amount: -40)).kind).to eq("spend")
    end

    it "is whatever it's told, so a Guess, or a Filing rule, takes precedence" do
      money_in = create(:budget_bank_transaction, account: splitwise_account, amount: 50)

      expect(described_class.for(money_in, kind: "deposit").kind).to eq("deposit")
    end

    it "doesn't ask for the Account when it's told the kind, which a Filing rule's bank transactions would make a query each for" do
      transactions = create_list(:budget_bank_transaction, 3, amount: 50).map { |transaction| Budget::BankTransaction.find(transaction.id) }

      queries = count_queries { transactions.each { |transaction| described_class.for(transaction, kind: "deposit") } }

      expect(queries).to eq(0)
    end
  end

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
