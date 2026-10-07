require "rails_helper"

# Scenarios 1, 2, 3, 11 and 12 of ADR 0016, as the month's figures after syncing from Splitwise and filing through the real operations: the sync (SyncSplitwise),
# filing (Budget::Filing) and Ignore (Budget::BankTransaction#ignore), and the figures from Budget::Month, which is the only place a balance is worked out. None of
# them counts the same money twice. Specs never reach Splitwise: SplitwiseFake holds the expenses.
RSpec.describe "Splitwise scenarios (ADR 0016)" do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:bank) { create(:budget_account, budget: budget, name: "Visa") }
  let(:connection) { create(:budget_bank_connection, budget: budget, login_id: "4321", access_token: "its-token", read_from: Date.new(2026, 10, 1)) }
  let!(:splitwise_account) { create(:budget_account, :synced, budget: budget, name: "Splitwise", bank_connection: connection) }

  let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:gas) { create(:budget_envelope, budget: budget, name: "Gas") }
  let!(:accommodation) { create(:budget_envelope, budget: budget, name: "Accommodation") }
  let(:envelopes) { [ dining_out, groceries, gas, accommodation ] }

  let(:october) { Date.new(2026, 10, 1) }

  before do
    splitwise.signs_in("code", as: Splitwise::Person.new(id: "4321", name: "Robert G."), token: "its-token")
    create(:budget_deposit, budget: budget, date: Date.new(2026, 10, 1), amount: 5000)
    envelopes.each { |envelope| create(:budget_assignment, envelope: envelope, month: october, amount: 500) }
  end

  def sync
    result = SyncSplitwise.call(connection)
    expect(result).to be_success
    result
  end

  def month(date = october)
    Budget::Month.new(budget, date)
  end

  # The figures of an envelope in a month, as the month view shows them.
  def figures(envelope, date = october)
    line = month(date).envelope_line(envelope.id)
    { spent: line.spent, refunded: line.refunded, available: line.available }
  end

  # Everything the month view says about the month, for comparing it before and after something that mustn't change it.
  def everything(date = october)
    { envelopes: envelopes.to_h { |envelope| [ envelope.name, figures(envelope, date) ] }, ready_to_assign: month(date).ready_to_assign.amount }
  end

  def transaction(external_id)
    splitwise_account.bank_transactions.find_by!(external_id: external_id.to_s)
  end

  # A card charge: the bank's own bank transaction, filed in full as the bank has it.
  def card_charge(description, amount, envelope, date: Date.new(2026, 10, 3))
    charge = create(:budget_bank_transaction, account: bank, description: description, amount: amount, date: date).reload
    file(charge, envelope)
  end

  # Filed as one record of its whole amount, as the filing form starts: a Spend for money out and, for Splitwise's money in, a Refund.
  def file(bank_transaction, envelope)
    entry = Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: [ Budget::Filing::Draft.for(bank_transaction, envelope_id: envelope.id) ])
    expect(Budget::Filing.new(budget).file([ entry ])).to be(true)
    bank_transaction.reload
  end

  # An e-transfer in the bank's Account, which is ignored, as the person ignores it.
  def ignored_e_transfer(description, amount, date)
    create(:budget_bank_transaction, account: bank, description: description, amount: amount, date: date).tap(&:ignore)
  end

  describe "1. I paid, split evenly" do
    it "leaves $50 spent on the dinner: the card charge is a $100 Spend, the Splitwise share a $50 Refund, and the e-transfer and settle-up change nothing" do
      card_charge("Nonna's #4412", -100, dining_out)
      splitwise.expense(1001, "Dinner at Nonna's", net_balance: "50.00", date: "2026-10-03")
      splitwise.expense(1002, "Jane paid me back", net_balance: "50.00", date: "2026-10-10", payment: true)

      result = sync
      share = file(transaction(1001), dining_out)
      jane_paid = ignored_e_transfer("INTERAC E-TRANSFER FROM JANE D", 50, Date.new(2026, 10, 10))
      before_settling = everything

      expect(result).to have_attributes(created: 1, settle_ups: 1)
      expect(share.filed_records).to contain_exactly(an_instance_of(Budget::Refund).and(have_attributes(amount: 50, date: Date.new(2026, 10, 3), envelope: dining_out)))
      expect(figures(dining_out)).to eq(spent: 100, refunded: 50, available: 450)
      expect(transaction(1002)).to be_ignored
      expect(jane_paid).to be_ignored

      # Nothing is left to settle: the ignored e-transfer and settle-up are the end of it, and Ready to Assign has no Deposit it didn't have.
      expect(everything).to eq(before_settling)
      expect(month.ready_to_assign.deposited).to eq(5000)
    end

    it "counts the share in the month of the expense, and not when Jane pays" do
      splitwise.expense(1001, "Dinner at Nonna's", net_balance: "50.00", date: "2026-10-31")
      sync

      file(transaction(1001), dining_out)

      expect(figures(dining_out, october)).to include(refunded: 50)
      expect(figures(dining_out, Date.new(2026, 11, 1))).to include(refunded: 0)
    end
  end

  describe "the date, at a month end" do
    # Splitwise stamps a day with midnight UTC, which is the day it shows, so that's the day a share counts in: in Eastern time it would be the evening before,
    # which puts an expense dated the 1st of a month in the month before it.
    def shared_dinner(id, date)
      splitwise.raw_expense({ "id" => id, "description" => "Dinner #{id}", "date" => date, "updated_at" => "2026-10-05T12:00:00Z", "currency_code" => "CAD", "payment" => false,
                              "users" => [ { "user_id" => 4321, "net_balance" => "50.00" } ] }, user_id: "4321")
    end

    it "counts an expense dated the last day of a month in that month, and one dated the 1st in the next, in the month's figures" do
      shared_dinner(1, "2026-10-31T00:00:00Z")
      shared_dinner(2, "2026-11-01T00:00:00Z")
      travel_to(Time.utc(2026, 11, 3, 12)) { sync }
      file(transaction(1), dining_out)
      file(transaction(2), dining_out)

      expect(transaction(1).date).to eq(Date.new(2026, 10, 31))
      expect(transaction(2).date).to eq(Date.new(2026, 11, 1))
      expect(figures(dining_out, october)).to include(refunded: 50)
      expect(figures(dining_out, Date.new(2026, 11, 1))).to include(refunded: 50)
    end

    it "reads a day the same at the end of it, whatever the time of day Splitwise stamped" do
      shared_dinner(1, "2026-10-31T23:59:59Z")

      sync

      expect(transaction(1).date).to eq(Date.new(2026, 10, 31))
    end
  end

  describe "2. Someone else paid" do
    it "is a $40 Spend from Groceries in the month of the expense, and the e-transfer months later and the settle-up are ignored" do
      splitwise.expense(2001, "Groceries for the cottage", net_balance: "-40.00", date: "2026-10-05")
      splitwise.expense(2002, "I paid Jane back", net_balance: "-40.00", date: "2027-01-15", payment: true)

      travel_to Time.utc(2027, 1, 20, 12) do
        sync
      end
      file(transaction(2001), groceries)
      ignored_e_transfer("INTERAC E-TRANSFER TO JANE D", -40, Date.new(2027, 1, 15))

      expect(transaction(2001).filed_records).to contain_exactly(an_instance_of(Budget::Spend).and(have_attributes(amount: 40, date: Date.new(2026, 10, 5), envelope: groceries)))
      expect(figures(groceries)).to eq(spent: 40, refunded: 0, available: 460)
      expect(transaction(2002)).to be_ignored

      # January's figures: nothing happened to any envelope when the e-transfer went out, only the carried over balance.
      expect(figures(groceries, Date.new(2027, 1, 1))).to include(spent: 0, refunded: 0)
    end
  end

  describe "3. Settling many at once" do
    it "files each share as it arrives and each card charge in full, and the e-transfer and its settle-ups touch no envelope" do
      splitwise.expense(3001, "Groceries at the cottage", net_balance: "-45.00", date: "2026-10-04")
      splitwise.expense(3002, "Gas up north", net_balance: "-30.00", date: "2026-10-04")
      splitwise.expense(3003, "Dinner out", net_balance: "-60.00", date: "2026-10-05")
      splitwise.expense(3004, "The cottage", net_balance: "-100.00", date: "2026-10-04")
      splitwise.expense(3005, "Dinner I paid for", net_balance: "35.00", date: "2026-10-05")
      sync
      { 3001 => groceries, 3002 => gas, 3003 => dining_out, 3004 => accommodation, 3005 => dining_out }.each { |id, envelope| file(transaction(id), envelope) }
      card_charge("Dinner I paid for", -70, dining_out, date: Date.new(2026, 10, 5))
      card_charge("Loblaws", -112.47, groceries, date: Date.new(2026, 10, 6))
      before_settling = everything

      splitwise.expense(3006, "Settle up", net_balance: "-312.47", date: "2026-10-12", payment: true)
      splitwise.expense(3007, "Settle up", net_balance: "-100.00", date: "2026-10-12", payment: true)
      result = sync
      ignored_e_transfer("INTERAC E-TRANSFER TO JANE D", -312.47, Date.new(2026, 10, 12))

      expect(result).to have_attributes(created: 0, settle_ups: 2)
      expect(transaction(3006)).to be_ignored
      expect(transaction(3007)).to be_ignored
      expect(everything).to eq(before_settling)
      expect(figures(groceries)).to include(spent: BigDecimal("157.47"))
      expect(figures(gas)).to include(spent: 30)
      expect(figures(accommodation)).to include(spent: 100)
      expect(figures(dining_out)).to include(spent: 60 + 70, refunded: 35)
    end
  end

  describe "11. I paid entirely for someone else" do
    it "is a Refund of the whole charge to the envelope the card charge was filed from, and none of it is Spent" do
      card_charge("Nonna's #4412", -100, dining_out)
      splitwise.expense(11001, "Dinner for Jane", net_balance: "100.00", date: "2026-10-03")
      sync

      file(transaction(11001), dining_out)

      expect(transaction(11001).filed_records).to contain_exactly(an_instance_of(Budget::Refund).and(have_attributes(amount: 100, envelope: dining_out)))
      expect(figures(dining_out)).to eq(spent: 100, refunded: 100, available: 500)
    end
  end

  describe "12. Edits and deletes after filing" do
    let!(:share) do
      splitwise.expense(12001, "Dinner at Nonna's", net_balance: "50.00", date: "2026-10-03")
      sync
      file(transaction(12001), dining_out)
    end

    it "updates the bank transaction in place and never a record: a changed share shows Doesn't add up, and the month's figures don't move" do
      refund = share.filed_records.sole
      before = everything
      splitwise.edit(12001, net_balance: "30.00")

      result = sync

      expect(result).to have_attributes(changed: 1, created: 0)
      expect(share.reload.amount).to eq(30)
      expect(share).to be_filed
      expect(share).not_to be_adds_up
      expect(refund.reload).to have_attributes(amount: 50, envelope: dining_out)
      expect(everything).to eq(before)
    end

    it "shows Deleted in Splitwise, with Un-file, when the expense is deleted, and the records and figures stay until the person un-files it" do
      before = everything
      splitwise.delete(12001)

      result = sync

      expect(result).to have_attributes(deleted: 1)
      expect(share.reload).to be_removed
      expect(share).to be_filed
      expect(everything).to eq(before)
      expect(Budget::Refund.count).to eq(1)

      share.unfile

      expect(Budget::Refund.count).to eq(0)
      expect(figures(dining_out)).to include(refunded: 0)
      expect(share.reload.state).to eq(:removed)
    end

    it "clears Deleted in Splitwise when the expense is restored, and the records and figures are as they were" do
      before = everything
      splitwise.delete(12001)
      sync
      splitwise.restore(12001)

      result = sync

      expect(result).to have_attributes(changed: 1, deleted: 0)
      expect(share.reload).not_to be_removed
      expect(share).to be_filed
      expect(share).to be_adds_up
      expect(everything).to eq(before)
    end

    it "leaves one that's deleted before it was filed out of the Unfiled state, and a restore puts it back, for the person to file" do
      splitwise.expense(12002, "Lunch", net_balance: "-20.00", date: "2026-10-04")
      sync
      splitwise.delete(12002)
      sync

      expect(splitwise_account.bank_transactions.unfiled).to be_empty

      splitwise.restore(12002)
      sync

      expect(splitwise_account.bank_transactions.unfiled.map(&:external_id)).to eq([ "12002" ])
    end

    it "shows Doesn't add up for a changed sign, though the size is the same" do
      splitwise.edit(12001, net_balance: "-50.00")

      sync

      expect(share.reload.amount).to eq(-50)
      expect(share).not_to be_adds_up
      expect(share.filed_total).to eq(50)
    end

    it "changes a past month's figures only when the person changes its records, as editing a past Spend does" do
      splitwise.edit(12001, net_balance: "30.00")
      sync
      expect(figures(dining_out)).to include(refunded: 50)

      share.filed_records.sole.update!(amount: 30)

      expect(figures(dining_out)).to include(refunded: 30)
      expect(share.reload).to be_adds_up
    end
  end
end
