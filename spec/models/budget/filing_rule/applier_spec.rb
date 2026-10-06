require "rails_helper"

# Applying Filing rules to bank transactions: each one is filed, or ignored, the way the most specific rule that fits it says, straight
# away and through the same filing operation a person uses (ADR 0012). It never touches one that's already filed or ignored.
RSpec.describe Budget::FilingRule::Applier do
  let(:budget) { create(:budget) }
  let(:account) { create(:budget_account, budget: budget) }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

  # As it's read back, which is what a rule is matched against: the database works out the normalised description.
  def bank_transaction(description = "LOBLAWS #1234 TORONTO", amount: -82.45, date: Date.new(2026, 9, 12))
    create(:budget_bank_transaction, account: account, description: description, amount: amount, date: date).reload
  end

  def rule(text, *traits, **attributes)
    create(:budget_filing_rule, *traits, **{ budget: budget, envelope: groceries, text: text }.merge(attributes))
  end

  def apply(*bank_transactions, **options)
    described_class.new(budget).apply(bank_transactions, **options)
  end

  describe "a Spend" do
    it "files money out as a Spend from the rule's envelope, of the whole amount, as the bank gave it, linked back to the bank transaction" do
      row = bank_transaction("LOBLAWS #1234 TORONTO", amount: -82.45, date: Date.new(2026, 9, 12))
      loblaws = rule("loblaws")

      result = apply(row)

      expect(result).to have_attributes(filed: 1, ignored: 0)
      spend = groceries.spends.sole
      expect(spend).to have_attributes(description: "LOBLAWS #1234 TORONTO", date: Date.new(2026, 9, 12), amount: BigDecimal("82.45"), notes: "")
      expect(row.reload).to be_filed
      expect(row.spend_links.sole.spend).to eq(spend)
      expect(row.filing_rule_id).to eq(loblaws.id)
      expect(row.filed_by_rule).to eq(loblaws)
    end
  end

  describe "a Refund" do
    it "files money in as a Refund to the rule's envelope" do
      row = bank_transaction("LOBLAWS RETURN", amount: 18.75)
      refund_rule = rule("loblaws return", :refund)

      expect(apply(row)).to have_attributes(filed: 1, ignored: 0)

      expect(groceries.refunds.sole).to have_attributes(description: "LOBLAWS RETURN", amount: BigDecimal("18.75"))
      expect(row.reload.filing_rule_id).to eq(refund_rule.id)
    end
  end

  describe "a Deposit" do
    it "files money in as a Deposit, which counts toward the month of its date, even at the end of one" do
      row = bank_transaction("ACME PAYROLL", amount: 3000, date: Date.new(2026, 9, 30))
      payroll = rule("payroll", :deposit)

      expect(apply(row)).to have_attributes(filed: 1, ignored: 0)

      expect(budget.deposits.sole).to have_attributes(description: "ACME PAYROLL", date: Date.new(2026, 9, 30), month: Date.new(2026, 9, 1), amount: 3000)
      expect(row.reload.filing_rule_id).to eq(payroll.id)
    end
  end

  describe "Ignore" do
    it "ignores the bank transaction, which makes no records, and says which rule did it" do
      row = bank_transaction("PAYMENT THANK YOU", amount: -250)
      payment = rule("payment thank you", :ignore)

      result = nil
      travel_to(Time.zone.local(2026, 9, 20, 9)) { result = apply(row) }

      expect(result).to have_attributes(filed: 0, ignored: 1)
      expect(row.reload).to be_ignored
      expect(row.ignored_at).to eq(Time.zone.local(2026, 9, 20, 9))
      expect(row.filing_rule_id).to eq(payment.id)
      expect(Budget::Spend.count + Budget::Refund.count + Budget::Deposit.count).to eq(0)
    end

    it "ignores money in too, since it fits either" do
      row = bank_transaction("PAYMENT THANK YOU", amount: 250)
      rule("payment thank you", :ignore)

      expect(apply(row)).to have_attributes(ignored: 1)
    end
  end

  describe "which rule" do
    it "is the most specific one that fits, for each bank transaction" do
      row = bank_transaction("LOBLAWS #1234 TORONTO")
      other = bank_transaction("COSTCO WHOLESALE")
      general = rule("loblaws")
      specific = rule("loblaws toronto", envelope: household)
      costco = rule("costco")

      expect(apply(row, other)).to have_attributes(filed: 2)

      expect(household.spends.sole.bank_transaction).to eq(row)
      expect(row.reload.filing_rule_id).to eq(specific.id)
      expect(other.reload.filing_rule_id).to eq(costco.id)
      expect(general.reload.bank_transactions).to be_empty
    end

    it "is none when no rule fits, and the bank transaction stays unfiled" do
      row = bank_transaction("SOMETHING ELSE")
      rule("loblaws")

      expect(apply(row)).to have_attributes(filed: 0, ignored: 0)

      expect(row.reload).to be_unfiled
      expect(row.filing_rule_id).to be_nil
    end

    it "is only the budget's own, so another budget's rule fits nothing here" do
      row = bank_transaction
      create(:budget_filing_rule, text: "loblaws")

      expect(apply(row)).to have_attributes(filed: 0, ignored: 0)
    end

    it "can be one rule only, which leaves the bank transactions another rule wins alone" do
      row = bank_transaction("LOBLAWS #1234 TORONTO")
      other = bank_transaction("LOBLAWS ON KING")
      general = rule("loblaws")
      rule("loblaws toronto", envelope: household)

      expect(apply(row, other, only: general)).to have_attributes(filed: 1)

      expect(row.reload).to be_unfiled
      expect(other.reload.filing_rule_id).to eq(general.id)
    end
  end

  describe "a bank transaction that's already filed or ignored" do
    it "is never touched, whatever fits it" do
      filed = create(:budget_bank_transaction, :filed, account: account, description: "LOBLAWS FILED").reload
      ignored = create(:budget_bank_transaction, :ignored, account: account, description: "LOBLAWS IGNORED").reload
      rule("loblaws")
      rule("loblaws ignored", :ignore)
      ignored_at = ignored.ignored_at

      expect { expect(apply(filed, ignored)).to have_attributes(filed: 0, ignored: 0) }
        .to not_change(Budget::Spend, :count).and not_change(Budget::SpendLink, :count)

      expect(filed.reload.filing_rule_id).to be_nil
      expect(ignored.reload).to have_attributes(ignored_at: ignored_at, filing_rule_id: nil)
    end

    it "is found out once the row is locked, so one filed since it was looked at is left alone" do
      row = bank_transaction
      stale = Budget::BankTransaction.find(row.id)
      create(:budget_spend_link, bank_transaction: row, spend: create(:budget_spend, envelope: household, amount: BigDecimal("82.45")))
      rule("loblaws")

      expect(apply(stale)).to have_attributes(filed: 0, ignored: 0)

      expect(row.reload.spend_links.size).to eq(1)
      expect(row.filing_rule_id).to be_nil
    end
  end

  describe "a rule for an archived envelope" do
    it "does nothing, as if it didn't exist, until the envelope is unarchived" do
      row = bank_transaction
      rule("loblaws")
      groceries.update!(archived_at: Time.current)

      expect(apply(row)).to have_attributes(filed: 0, ignored: 0)
      expect(row.reload).to be_unfiled

      groceries.update!(archived_at: nil)

      expect(apply(row)).to have_attributes(filed: 1)
      expect(row.reload).to be_filed
    end

    it "leaves the bank transaction unfiled when the envelope was archived after the rules were loaded, and files the others" do
      doomed = bank_transaction("LOBLAWS #1234")
      fine = bank_transaction("COSTCO WHOLESALE")
      rule("loblaws")
      rule("costco", envelope: household)
      applier = described_class.new(budget)
      groceries.update!(archived_at: Time.current)

      expect(applier.apply([ doomed, fine ])).to have_attributes(filed: 1, ignored: 0)

      expect(doomed.reload).to be_unfiled
      expect(fine.reload).to be_filed
    end
  end

  it "does nothing, and files nothing, when it's given nothing" do
    rule("loblaws")

    expect(apply).to have_attributes(filed: 0, ignored: 0)
  end

  it "does all of it in one database transaction, so a failure leaves nothing filed or ignored" do
    first = bank_transaction("LOBLAWS #1234")
    second = bank_transaction("PAYMENT THANK YOU")
    rule("loblaws")
    rule("payment thank you", :ignore)
    allow(Budget::BankTransaction).to receive(:note_filing_rules).and_wrap_original do |original, *args, **options|
      options[:ignored_at] ? raise(ActiveRecord::StatementInvalid, "the database went away") : original.call(*args, **options)
    end

    expect { apply(first, second) }.to raise_error(ActiveRecord::StatementInvalid)

    expect(first.reload).to be_unfiled
    expect(second.reload).to be_unfiled
    expect(Budget::Spend.count).to eq(0)
  end

  describe "the number of queries" do
    def rows(count, description)
      Array.new(count) { |n| bank_transaction("#{description} #{n}") }
    end

    it "is the same for 10 bank transactions as for 100" do
      rule("alpha")
      rule("beta", :ignore)
      few = rows(5, "alpha") + rows(5, "beta")
      many = rows(50, "alpha") + rows(50, "beta")

      small = count_queries { described_class.new(budget).apply(few) }
      large = count_queries { described_class.new(budget).apply(many) }

      expect(large).to eq(small)
      expect(Budget::Spend.count).to eq(55)
      expect(Budget::BankTransaction.where.not(ignored_at: nil).count).to eq(55)
    end

    it "is the same for 1 rule as for 100" do
      rule("alpha one")
      rule("beta one", :ignore)
      few = [ bank_transaction("alpha one"), bank_transaction("beta one") ]
      small = count_queries { described_class.new(budget).apply(few) }

      many_rules = Array.new(50) { |n| rule("alpha #{(n + 100).to_s.tr("0-9", "a-j")}") } + Array.new(50) { |n| rule("beta #{(n + 100).to_s.tr("0-9", "a-j")}", :ignore) }
      many = many_rules.map { |each| bank_transaction(each.text) }
      large = count_queries { described_class.new(budget).apply(many) }

      expect(large).to eq(small)
      expect(Budget::Spend.count).to eq(51)
      expect(many.map { |row| row.reload.filing_rule_id }).to match_array(many_rules.map(&:id))
    end
  end
end
