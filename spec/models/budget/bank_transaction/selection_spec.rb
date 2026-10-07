require "rails_helper"

# Several bank transactions chosen on the Bank transactions page and filed, ignored, un-filed, un-ignored or marked reviewed in one go. All or none, except
# Mark reviewed, which is lenient; the rows are locked and judged once the locks are held; and the same number of queries for 5 rows as for 50.
RSpec.describe Budget::BankTransaction::Selection do
  let(:budget) { create(:budget) }
  let(:account) { create(:budget_account, budget: budget) }
  let!(:travel) { create(:budget_envelope, budget: budget, name: "Travel") }

  def selection(*rows)
    described_class.new(budget, rows.flatten.map(&:id))
  end

  def unfiled(description = "Hotel", amount: -100, date: Date.new(2026, 9, 12))
    create(:budget_bank_transaction, account: account, description: description, amount: amount, date: date)
  end

  describe "#file_to" do
    it "files money out as a Spend and money in as a Refund of the whole amount to the envelope, with the bank's description and date and no notes" do
      hotel = unfiled("Hotel", amount: -100, date: Date.new(2026, 9, 12))
      refund = unfiled("Hotel refund", amount: 25, date: Date.new(2026, 9, 14))

      expect(selection(hotel, refund).file_to(travel.id)).to be(true)

      expect(travel.spends.sole).to have_attributes(description: "Hotel", date: Date.new(2026, 9, 12), amount: 100, notes: "")
      expect(travel.refunds.sole).to have_attributes(description: "Hotel refund", date: Date.new(2026, 9, 14), amount: 25, notes: "")
      expect([ hotel, refund ].map { |row| row.reload.filed? }).to all(be(true))
    end

    it "notes no Filing rule, so what it files isn't to review, and makes no rule" do
      hotel = unfiled

      selection(hotel).file_to(travel.id)

      expect(hotel.reload).to have_attributes(filing_rule_id: nil)
      expect(hotel).not_to be_to_review
      expect(Budget::FilingRule.count).to eq(0)
    end

    it "files none, naming the first row that stopped it, when a row was filed since the page was drawn" do
      first = unfiled("First", date: Date.new(2026, 9, 14))
      filed_elsewhere = unfiled("Costco #99", date: Date.new(2026, 9, 13))
      chosen = selection(first, filed_elsewhere)
      create(:budget_spend_link, bank_transaction: filed_elsewhere, spend: create(:budget_spend, envelope: travel, amount: 100))

      expect(chosen.file_to(travel.id)).to be(false)

      expect(chosen.refusal).to eq("Nothing was filed. Costco #99: This bank transaction is already filed.")
      expect(first.reload).to be_unfiled
      expect(travel.spends.count).to eq(1)
    end

    it "files none when a row was ignored since, or went from Splitwise" do
      ignored = unfiled("Ignored one")
      splitwise = create(:budget_account, :synced, budget: budget)
      removed = create(:budget_bank_transaction, :removed, account: splitwise, description: "Gone")

      expect(selection(ignored).tap { |chosen| ignored.update!(ignored_at: Time.current) }.file_to(travel.id)).to be(false)
      expect(selection(removed).tap { |chosen| chosen.file_to(travel.id) }.refusal).to eq("Nothing was filed. Gone: This bank transaction was deleted in Splitwise, so it can't be filed.")
    end

    it "files none when the envelope is archived since, which is the words filing as guessed uses" do
      hotel = unfiled("COSTCO #99")
      travel.archive!

      chosen = selection(hotel)

      expect(chosen.file_to(travel.id)).to be(false)
      expect(chosen.refusal).to eq("Nothing was filed. COSTCO #99: Envelope is archived.")
    end

    it "files none to another budget's envelope, or none, which isn't an envelope of its own" do
      other = create(:budget_envelope, name: "Theirs")
      hotel = unfiled

      expect(selection(hotel).file_to(other.id)).to be(false)
      expect(selection(hotel).file_to(nil)).to be(false)
      expect(hotel.reload).to be_unfiled
    end
  end

  describe "finding them" do
    it "is a not found for a bank transaction of another budget, so nothing at all is done" do
      other = create(:budget_bank_transaction)

      expect { described_class.new(budget, [ unfiled.id, other.id ]) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "counts each once" do
      hotel = unfiled

      expect(described_class.new(budget, [ hotel.id, hotel.id.to_s ]).count).to eq(1)
    end
  end

  describe "#ignore" do
    it "ignores them all, noting no Filing rule, so what a person chose isn't to review" do
      first = unfiled("One")
      second = unfiled("Two")

      expect(selection(first, second).ignore).to be(true)

      expect([ first, second ].map { |row| row.reload.ignored? }).to all(be(true))
      expect([ first, second ].map(&:to_review?)).to all(be(false))
    end

    it "ignores none, naming the row, when one is filed or already ignored" do
      first = unfiled("One", date: Date.new(2026, 9, 14))
      filed = create(:budget_bank_transaction, :filed, account: account, description: "Filed", date: Date.new(2026, 9, 13))
      ignored = create(:budget_bank_transaction, :ignored, account: account, description: "Ignored", date: Date.new(2026, 9, 12))

      chosen = selection(first, filed)
      expect(chosen.ignore).to be(false)
      expect(chosen.refusal).to eq("Nothing was ignored. Filed: This bank transaction is filed. Un-file it before ignoring it.")
      chosen = selection(first, ignored)
      expect(chosen.ignore).to be(false)
      expect(chosen.refusal).to eq("Nothing was ignored. Ignored: This bank transaction is already ignored.")
      expect(first.reload).to be_unfiled
    end
  end

  describe "#unignore" do
    it "un-ignores them all, which are no longer a rule's" do
      first = create(:budget_bank_transaction, :ignored, :by_rule, account: account)
      second = create(:budget_bank_transaction, :ignored, account: account)

      expect(selection(first, second).unignore).to be(true)

      expect([ first, second ].map { |row| row.reload.ignored? }).to all(be(false))
      expect(first.filing_rule_id).to be_nil
    end

    it "un-ignores none, naming the row, when one isn't ignored" do
      ignored = create(:budget_bank_transaction, :ignored, account: account)
      other = unfiled("Not ignored")

      chosen = selection(ignored, other)

      expect(chosen.unignore).to be(false)
      expect(chosen.refusal).to eq("Nothing was un-ignored. Not ignored: This bank transaction isn't ignored.")
      expect(ignored.reload).to be_ignored
    end
  end

  describe "#unfile" do
    it "deletes the records they were filed as and their links, which leaves them unfiled and no longer a rule's" do
      first = create(:budget_bank_transaction, :filed, :by_rule, account: account)
      second = create(:budget_bank_transaction, :filed, account: account, amount: 50)

      expect(selection(first, second).unfile).to be(true)

      expect([ first, second ].map { |row| row.reload.unfiled? }).to all(be(true))
      expect(first.filing_rule_id).to be_nil
      expect([ Budget::Spend.count, Budget::Deposit.count, Budget::SpendLink.count, Budget::DepositLink.count ]).to eq([ 0, 0, 0, 0 ])
    end

    it "un-files none, naming the row, when one isn't filed" do
      filed = create(:budget_bank_transaction, :filed, account: account)
      ignored = create(:budget_bank_transaction, :ignored, account: account, description: "Ignored one")

      chosen = selection(filed, ignored)

      expect(chosen.unfile).to be(false)
      expect(chosen.refusal).to eq("Nothing was un-filed. Ignored one: This bank transaction isn't filed.")
      expect(filed.reload).to be_filed
      expect(Budget::Spend.count).to eq(1)
    end
  end

  describe "#mark_reviewed" do
    it "marks the ones that are to review and says how many, skipping one that isn't any more without refusing the rest" do
      first = create(:budget_bank_transaction, :filed, :by_rule, account: account)
      second = create(:budget_bank_transaction, :ignored, :by_rule, account: account)
      unfiled_again = create(:budget_bank_transaction, :filed, :by_rule, account: account)
      chosen = selection(first, second, unfiled_again)
      unfiled_again.unfile

      expect(chosen.mark_reviewed).to eq(2)

      expect([ first, second ].map { |row| row.reload.to_review? }).to all(be(false))
      expect(first.reviewed_at).to be_present
    end
  end

  describe "the number of queries" do
    it "is the same for 5 rows as for 50, whichever it does" do
      {
        file_to: [ [], ->(chosen) { chosen.file_to(travel.id) } ],
        ignore: [ [], ->(chosen) { chosen.ignore } ],
        unignore: [ [ :ignored ], ->(chosen) { chosen.unignore } ],
        unfile: [ [ :filed ], ->(chosen) { chosen.unfile } ],
        mark_reviewed: [ [ :filed, :by_rule ], ->(chosen) { chosen.mark_reviewed } ]
      }.each do |name, (traits, action)|
        counts = [ 5, 50 ].map do |count|
          chosen = selection(Array.new(count) { |n| create(:budget_bank_transaction, *traits, account: account, description: "#{name} #{count} #{n}") })
          count_queries { action.call(chosen) }
        end

        expect(counts.first).to eq(counts.last), "#{name} ran #{counts.first} queries for 5 rows and #{counts.last} for 50"
      end
    end
  end
end
