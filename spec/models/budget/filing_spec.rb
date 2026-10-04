require "rails_helper"

# Filing is one operation: it takes bank transactions, each with the records it's filed as, and files them all, or none (ADR 0009).
# A person calls it from the filing form with one bank transaction, and Filing rules and a Guess will call the same operation.
RSpec.describe Budget::Filing do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:account) { create(:budget_account, budget: budget) }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

  def bank_transaction(amount, **attributes)
    create(:budget_bank_transaction, account: account, amount: amount, description: "COSTCO #123", date: Date.new(2026, 9, 12), **attributes)
  end

  def draft(kind, amount, **attributes)
    Budget::Filing::Draft.new({ kind: kind, envelope_id: (groceries.id unless kind == "deposit"), description: "Costco", date: Date.new(2026, 9, 12), amount: amount, notes: "" }.merge(attributes))
  end

  def entry(bank_transaction, *drafts)
    Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: drafts)
  end

  # Files the entries, and gives back the Filing, which has them with what was wrong.
  def file(*entries)
    Budget::Filing.new(budget).tap { |filing| filing.file(entries) }
  end

  def refused_with(filing, entry)
    [ filing.filed?, entry.errors.full_messages, entry.drafts.flat_map { |draft| draft.errors.full_messages } ]
  end

  describe "money out" do
    it "is filed as a Spend, with the bank transaction's date and description as given, and a link back to it" do
      money_out = bank_transaction(-100)

      filing = file(entry(money_out, draft("spend", "100", description: "Costco run", notes: "Bulk buy")))

      expect(filing.filed?).to be(true)
      spend = groceries.spends.sole
      expect(spend).to have_attributes(description: "Costco run", date: Date.new(2026, 9, 12), amount: 100, notes: "Bulk buy")
      expect(money_out.reload).to be_filed
      expect(money_out.spend_links.sole.spend).to eq(spend)
      expect(spend.bank_transaction).to eq(money_out)
    end

    it "is never filed as a Deposit or a Refund" do
      money_out = bank_transaction(-100)

      [ draft("deposit", "100"), draft("refund", "100") ].each do |wrong|
        entry = entry(money_out, wrong)
        filing = file(entry)

        expect(filing.filed?).to be(false)
        expect(wrong.errors.full_messages).to eq([ "Kind must be Spend, since the money went out" ])
      end
      expect(Budget::Deposit.count + Budget::Refund.count).to eq(0)
      expect(money_out.reload).to be_unfiled
    end

    it "is never filed as a Reallocation, which isn't a kind it knows" do
      entry = entry(bank_transaction(-100), draft("reallocation", "100"))

      expect(file(entry).filed?).to be(false)
      expect(entry.drafts.first.errors.full_messages).to eq([ "Kind must be Spend, since the money went out" ])
    end
  end

  describe "money in" do
    it "is filed as a Deposit, which counts toward the month of its date unless it's chosen for the month after" do
      money_in = bank_transaction(3000, description: "ACME PAYROLL")

      file(entry(money_in, draft("deposit", "3000", description: "Paycheck")))

      deposit = budget.deposits.sole
      expect(deposit).to have_attributes(description: "Paycheck", date: Date.new(2026, 9, 12), month: Date.new(2026, 9, 1), amount: 3000)
      expect(money_in.reload.deposit_links.sole.deposit).to eq(deposit)
    end

    it "is filed as a Deposit for the month after, as an ordinary Deposit can be (ADR 0005)" do
      money_in = bank_transaction(3000)

      file(entry(money_in, draft("deposit", "3000", month: Date.new(2026, 10, 1))))

      expect(budget.deposits.sole.month).to eq(Date.new(2026, 10, 1))
    end

    it "is refused a month that isn't the date's or the one after" do
      entry = entry(bank_transaction(3000), draft("deposit", "3000", month: Date.new(2026, 12, 1)))

      expect(file(entry).filed?).to be(false)
      expect(entry.drafts.first.errors.full_messages).to eq([ "Ready to Assign in must be September 2026 or October 2026" ])
    end

    it "is filed as a Refund to an envelope" do
      money_in = bank_transaction(12.25)

      file(entry(money_in, draft("refund", "12.25", envelope_id: household.id, description: "Hydro rebate")))

      expect(household.refunds.sole).to have_attributes(description: "Hydro rebate", amount: BigDecimal("12.25"), date: Date.new(2026, 9, 12))
      expect(money_in.reload.refund_links.sole.refund).to eq(household.refunds.sole)
    end

    it "is never filed as a Spend" do
      entry = entry(bank_transaction(100), draft("spend", "100"))

      expect(file(entry).filed?).to be(false)
      expect(entry.drafts.first.errors.full_messages).to eq([ "Kind must be Deposit or Refund, since the money came in" ])
    end
  end

  describe "the amount, which must be the bank transaction's whole amount" do
    it "is refused when the records add up to less, saying by how much" do
      money_out = bank_transaction(-100)
      entry = entry(money_out, draft("spend", "60"))

      filing = file(entry)

      expect(refused_with(filing, entry)).to eq([ false, [ "The records add up to $60.00, which is $40.00 less than the bank transaction's $100.00." ], [] ])
      expect(budget.spends).to be_empty
      expect(money_out.reload).to be_unfiled
    end

    it "is refused when the records add up to more, saying by how much" do
      entry = entry(bank_transaction(-100), draft("spend", "100.50"))

      filing = file(entry)

      expect(refused_with(filing, entry)).to eq([ false, [ "The records add up to $100.50, which is $0.50 more than the bank transaction's $100.00." ], [] ])
    end

    it "is the amount as a positive figure, whichever way the money went" do
      expect(file(entry(bank_transaction(-100), draft("spend", "100"))).filed?).to be(true)
      expect(file(entry(bank_transaction(100), draft("refund", "100"))).filed?).to be(true)
    end

    it "is refused when it's a negative figure, which no record has" do
      entry = entry(bank_transaction(-100), draft("spend", "-100"))

      expect(file(entry).filed?).to be(false)
      expect(entry.drafts.first.errors.full_messages).to eq([ "Amount must be greater than 0" ])
    end

    it "isn't checked when a record is refused for something else, which is said first" do
      entry = entry(bank_transaction(-100), draft("spend", "60", description: ""))

      filing = file(entry)

      expect(refused_with(filing, entry)).to eq([ false, [], [ "Description can't be blank" ] ])
    end

    it "is exact to the cent, so a figure that rounds the same isn't enough" do
      entry = entry(bank_transaction(-100.10), draft("spend", "100.1"))
      expect(file(entry).filed?).to be(true)

      entry = entry(bank_transaction(-100.10), draft("spend", "100.099"))
      expect(file(entry).filed?).to be(false)
      expect(entry.drafts.first.errors.full_messages).to eq([ "Amount can't have more than 2 decimal places" ])
    end
  end

  describe "what's wrong with a record" do
    it "is on the record, as it would be on a typed-in one, and nothing is created" do
      money_out = bank_transaction(-100)
      bad = draft("spend", "1.005", description: " ", date: nil, envelope_id: nil)
      entry = entry(money_out, bad)

      filing = file(entry)

      expect(filing.filed?).to be(false)
      expect(bad.errors.full_messages).to contain_exactly(
        "Envelope can't be blank", "Description can't be blank", "Date can't be blank", "Amount can't have more than 2 decimal places"
      )
      expect(Budget::Spend.count).to eq(0)
      expect(Budget::SpendLink.count).to eq(0)
    end

    it "says another budget's envelope is no envelope, as for a Spend, and so is one that doesn't exist" do
      others = create(:budget_envelope, name: "Someone else's")
      [ others.id, 0, "not-an-id", "" ].each do |envelope_id|
        bad = draft("spend", "100", envelope_id: envelope_id)

        expect(file(entry(bank_transaction(-100), bad)).filed?).to be(false)
        expect(bad.errors.full_messages).to eq([ "Envelope can't be blank" ])
      end
      expect(Budget::Spend.count).to eq(0)
    end

    it "says an archived envelope is archived (ADR 0008)" do
      groceries.update_column(:archived_at, Time.current)
      bad = draft("spend", "100")

      expect(file(entry(bank_transaction(-100), bad)).filed?).to be(false)
      expect(bad.errors.full_messages).to eq([ "Envelope is archived" ])
    end

    it "says a kind it doesn't know isn't one, or that it's blank" do
      [ "income", "", nil ].each do |kind|
        bad = draft(kind, "100")

        expect(file(entry(bank_transaction(-100), bad)).filed?).to be(false)
        expect(bad.errors.full_messages).to eq([ "Kind must be Spend, since the money went out" ])
      end
    end

    it "needs at least one record, and no more than 50" do
      empty = entry(bank_transaction(-100))
      expect(file(empty).filed?).to be(false)
      expect(empty.errors.full_messages).to eq([ "File it as at least one record." ])

      many = entry(bank_transaction(-100), *Array.new(51) { draft("spend", "1") })
      expect(file(many).filed?).to be(false)
      expect(many.errors.full_messages).to eq([ "A bank transaction can be filed as at most 50 records." ])
    end
  end

  describe "a bank transaction that isn't unfiled" do
    it "can't be filed again, and creates nothing" do
      filed = bank_transaction(-100, account: account)
      create(:budget_spend_link, bank_transaction: filed, spend: create(:budget_spend, envelope: groceries, amount: 100))
      entry = entry(filed.reload, draft("spend", "100"))

      filing = file(entry)

      expect(refused_with(filing, entry)).to eq([ false, [ "This bank transaction is already filed." ], [] ])
      expect(Budget::Spend.count).to eq(1)
    end

    it "can't be filed once it's ignored, and creates nothing" do
      ignored = bank_transaction(-100, ignored_at: Time.current)
      entry = entry(ignored, draft("spend", "100"))

      filing = file(entry)

      expect(refused_with(filing, entry)).to eq([ false, [ "This bank transaction is ignored. Un-ignore it first." ], [] ])
      expect(Budget::Spend.count).to eq(0)
    end

    it "is judged once it's locked, so a double submit files once" do
      money_out = bank_transaction(-100)
      stale = Budget::BankTransaction.find(money_out.id) # What the second submit looked at, before the first was done.

      expect(file(entry(money_out, draft("spend", "100"))).filed?).to be(true)
      second = entry(stale, draft("spend", "100"))
      filing = file(second)

      expect(filing.filed?).to be(false)
      expect(second.errors.full_messages).to eq([ "This bank transaction is already filed." ])
      expect(Budget::Spend.count).to eq(1)
    end

    it "is judged once it's locked for being ignored since it was looked at, too" do
      money_out = bank_transaction(-100)
      stale = Budget::BankTransaction.find(money_out.id)
      money_out.ignore

      second = entry(stale, draft("spend", "100"))

      expect(file(second).filed?).to be(false)
      expect(second.errors.full_messages).to eq([ "This bank transaction is ignored. Un-ignore it first." ])
    end

    it "can't be another budget's, which no one can reach to file" do
      others = create(:budget_bank_transaction, amount: -100)
      entry = entry(others, draft("spend", "100"))

      expect(file(entry).filed?).to be(false)
      expect(entry.errors.full_messages).to eq([ "This bank transaction isn't in this budget." ])
      expect(Budget::Spend.count).to eq(0)
    end
  end

  describe "several bank transactions at once" do
    it "files them all, each as its own records" do
      out = bank_transaction(-100)
      into = bank_transaction(3000)

      filing = file(entry(out, draft("spend", "100")), entry(into, draft("deposit", "3000")))

      expect(filing.filed?).to be(true)
      expect(out.reload).to be_filed
      expect(into.reload).to be_filed
      expect(budget.spends.count).to eq(1)
      expect(budget.deposits.count).to eq(1)
    end

    it "files none of them when one of them is refused, and says which" do
      good = entry(bank_transaction(-100), draft("spend", "100"))
      bad = entry(bank_transaction(-50), draft("spend", "40"))

      filing = file(good, bad)

      expect(filing.filed?).to be(false)
      expect(good.errors).to be_empty
      expect(bad.errors.full_messages).to eq([ "The records add up to $40.00, which is $10.00 less than the bank transaction's $50.00." ])
      expect(Budget::Spend.count).to eq(0)
      expect(Budget::SpendLink.count).to eq(0)
    end

    it "files none of them when one has been filed since, which is only found out once they're locked" do
      first = bank_transaction(-100)
      second = bank_transaction(-50)
      stale = Budget::BankTransaction.find(second.id)
      create(:budget_spend_link, bank_transaction: second, spend: create(:budget_spend, envelope: groceries, amount: 50))

      filing = file(entry(first, draft("spend", "100")), entry(stale, draft("spend", "50")))

      expect(filing.filed?).to be(false)
      expect(first.reload).to be_unfiled
      expect(Budget::Spend.count).to eq(1)
    end

    it "does nothing, and is filed, when there's nothing to file" do
      expect(Budget::Filing.new(budget).file([])).to be(true)
    end

    it "makes the same number of queries for 1 bank transaction as for 50, of the same kinds" do
      one = [ entry(bank_transaction(-100), draft("spend", "100")) ]
      fifty = Array.new(50) { entry(bank_transaction(-100), draft("spend", "100")) }

      few = count_queries { Budget::Filing.new(budget).file(one) }
      many = count_queries { Budget::Filing.new(budget).file(fifty) }

      expect(many).to eq(few)
      expect(budget.spends.count).to eq(51)
    end

    it "makes the same number of queries whatever the mix of kinds it files, up to one insert for each" do
      mixed = [ entry(bank_transaction(-100), draft("spend", "100")), entry(bank_transaction(10), draft("refund", "10")),
                entry(bank_transaction(3000), draft("deposit", "3000")) ]
      more = Array.new(10) { [ entry(bank_transaction(-100), draft("spend", "100")), entry(bank_transaction(10), draft("refund", "10")), entry(bank_transaction(3000), draft("deposit", "3000")) ] }.flatten

      few = count_queries { Budget::Filing.new(budget).file(mixed) }
      many = count_queries { Budget::Filing.new(budget).file(more) }

      expect(many).to eq(few)
    end
  end

  describe Budget::Filing::Draft do
    it "starts as what a bank transaction would be filed as: its date and description, and the whole amount as a positive figure" do
      out = bank_transaction(-82.45, description: "LOBLAWS #1234", date: Date.new(2026, 9, 2))

      draft = Budget::Filing::Draft.for(out)

      expect(draft).to have_attributes(kind: "spend", description: "LOBLAWS #1234", date: Date.new(2026, 9, 2), amount: BigDecimal("82.45"), notes: "", envelope_id: nil, month: nil)
    end

    it "starts as a Deposit for money in, which is the kind most money in is" do
      expect(Budget::Filing::Draft.for(bank_transaction(2800)).kind).to eq("deposit")
    end

    it "takes what it's told over what it would start as" do
      draft = Budget::Filing::Draft.for(bank_transaction(-10), kind: "spend", envelope_id: groceries.id, description: "Costco")

      expect(draft).to have_attributes(kind: "spend", envelope_id: groceries.id, description: "Costco")
    end
  end
end
