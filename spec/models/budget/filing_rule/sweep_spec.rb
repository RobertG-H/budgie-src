require "rails_helper"

# When a Filing rule is saved it can sweep the unfiled bank transactions it already fits, so that a rule made after an Import tidies that
# Import up too. It files and ignores them the way the rule says, through the filing operation, and never touches one that's filed or ignored.
RSpec.describe Budget::FilingRule::Sweep do
  let(:budget) { create(:budget) }
  let(:account) { create(:budget_account, budget: budget) }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

  def bank_transaction(description, amount: -50, account: self.account, date: Date.new(2026, 9, 12))
    create(:budget_bank_transaction, account: account, description: description, amount: amount, date: date)
  end

  def rule(text, *traits, **attributes)
    create(:budget_filing_rule, *traits, **{ budget: budget, envelope: groceries, text: text }.merge(attributes))
  end

  describe "#run" do
    it "files the other unfiled bank transactions the rule fits, and leaves filed ones, ignored ones and ones it doesn't fit alone" do
      first, second, third = %w[ LOBLAWS\ #1 LOBLAWS\ #2 LOBLAWS\ #3 ].map { |description| bank_transaction(description) }
      filed = create(:budget_bank_transaction, :filed, account: account, description: "LOBLAWS FILED")
      ignored = create(:budget_bank_transaction, :ignored, account: account, description: "LOBLAWS IGNORED")
      other = bank_transaction("COSTCO")
      loblaws = rule("loblaws")

      result = described_class.new(loblaws).run

      expect(result).to have_attributes(filed: 3, ignored: 0)
      expect([ first, second, third ].map { |row| row.reload.filed? }).to all(be(true))
      expect(groceries.spends.pluck(:description)).to contain_exactly("LOBLAWS #1", "LOBLAWS #2", "LOBLAWS #3")
      expect(filed.reload.filing_rule_id).to be_nil
      expect(ignored.reload).to have_attributes(filing_rule_id: nil)
      expect(other.reload).to be_unfiled
    end

    it "notes the rule on each bank transaction it files, which is what filed it" do
      rows = Array.new(3) { |n| bank_transaction("LOBLAWS ##{n}") }
      loblaws = rule("loblaws")

      described_class.new(loblaws).run

      expect(rows.map { |row| row.reload.filing_rule_id }).to eq([ loblaws.id ] * 3)
      expect(rows.map(&:filed_by_rule)).to eq([ loblaws ] * 3)
    end

    it "ignores them for an Ignore rule, money in or out, and files money in for a Deposit or a Refund" do
      out = bank_transaction("PAYMENT THANK YOU", amount: -250)
      back = bank_transaction("PAYMENT THANK YOU", amount: 250, date: Date.new(2026, 9, 13))
      payment = rule("payment thank you", :ignore)

      expect(described_class.new(payment).run).to have_attributes(filed: 0, ignored: 2)
      expect([ out.reload, back.reload ]).to all(be_ignored)
      expect([ out.filing_rule_id, back.filing_rule_id ]).to eq([ payment.id ] * 2)

      incoming = bank_transaction("ACME PAYROLL", amount: 3000)
      payroll = rule("payroll", :deposit)

      expect(described_class.new(payroll).run).to have_attributes(filed: 1)
      expect(incoming.reload.deposit_links.sole.deposit).to have_attributes(amount: 3000, month: Date.new(2026, 9, 1))
    end

    it "fits the rule's own conditions, an Account and an amount, since the rule can have them" do
      other_account = create(:budget_account, budget: budget)
      right = bank_transaction("LOBLAWS", amount: -82.45)
      wrong_account = bank_transaction("LOBLAWS", amount: -82.45, account: other_account)
      wrong_amount = bank_transaction("LOBLAWS", amount: -10)
      pinned = rule("loblaws", account: account, amount: "-82.45")

      expect(described_class.new(pinned).run).to have_attributes(filed: 1)

      expect(right.reload).to be_filed
      expect([ wrong_account.reload, wrong_amount.reload ]).to all(be_unfiled)
    end

    it "leaves a bank transaction that a more specific rule fits to that rule, so a sweep never undoes the order rules run in" do
      rule("loblaws #1234", envelope: household)
      specific = bank_transaction("LOBLAWS #1234 TORONTO")
      general_only = bank_transaction("LOBLAWS ON KING")
      loblaws = rule("loblaws")

      expect(described_class.new(loblaws).run).to have_attributes(filed: 1)

      expect(general_only.reload.filing_rule_id).to eq(loblaws.id)
      expect(specific.reload).to be_unfiled
    end

    it "does nothing for a rule on an archived envelope" do
      row = bank_transaction("LOBLAWS")
      loblaws = rule("loblaws")
      groceries.update!(archived_at: Time.current)

      expect(described_class.new(loblaws.reload).run).to have_attributes(filed: 0, ignored: 0)
      expect(row.reload).to be_unfiled
    end

    it "is one database transaction, so a failure leaves nothing filed" do
      first = bank_transaction("LOBLAWS #1")
      second = bank_transaction("LOBLAWS #2")
      loblaws = rule("loblaws")
      allow(Budget::BankTransaction).to receive(:note_filing_rules).and_raise(ActiveRecord::StatementInvalid, "the database went away")

      expect { described_class.new(loblaws).run }.to raise_error(ActiveRecord::StatementInvalid)

      expect([ first.reload, second.reload ]).to all(be_unfiled)
      expect(Budget::Spend.count).to eq(0)
    end

    it "makes the same number of queries for 1 bank transaction as for 100" do
      few_rule = rule("alpha")
      many_rule = rule("beta")
      bank_transaction("ALPHA 1")
      Array.new(100) { |n| bank_transaction("BETA #{n}") }

      few = count_queries { described_class.new(few_rule).run }
      many = count_queries { described_class.new(many_rule).run }

      expect(many).to eq(few)
      expect(groceries.spends.count).to eq(101)
    end
  end

  describe "#bank_transactions and #count" do
    it "are what #run would file or ignore, and don't change anything" do
      rows = Array.new(3) { |n| bank_transaction("LOBLAWS ##{n}") }
      bank_transaction("COSTCO")
      loblaws = rule("loblaws")
      sweep = described_class.new(loblaws)

      expect(sweep.count).to eq(3)
      expect(sweep.bank_transactions).to match_array(rows)
      expect(rows.map { |row| row.reload.state }).to all(eq(:unfiled))
      expect(sweep.run).to have_attributes(filed: 3)
    end

    it "have #left_to_other_rules, which the rule fits but a more specific rule files, so a form can say why they aren't counted" do
      rule("loblaws #1234", envelope: household)
      specific = bank_transaction("LOBLAWS #1234 TORONTO")
      mine = bank_transaction("LOBLAWS ON KING")
      bank_transaction("COSTCO")
      create(:budget_bank_transaction, :filed, account: account, description: "LOBLAWS #1234 FILED")
      loblaws = rule("loblaws")

      sweep = described_class.new(loblaws)

      expect(sweep.bank_transactions).to eq([ mine ])
      expect(sweep.left_to_other_rules).to eq([ specific ])
    end

    it "have none left to other rules for a rule on an archived envelope, which fits nothing in effect, or when no other rule is more specific" do
      row = bank_transaction("LOBLAWS")
      loblaws = rule("loblaws")
      expect(described_class.new(loblaws).left_to_other_rules).to be_empty

      rule("loblaws toronto", envelope: household)
      groceries.update!(archived_at: Time.current)
      expect(described_class.new(loblaws.reload).left_to_other_rules).to be_empty
      expect(row.reload).to be_unfiled
    end

    it "count only the unfiled ones, never a filed or an ignored one" do
      create(:budget_bank_transaction, :filed, account: account, description: "LOBLAWS FILED")
      create(:budget_bank_transaction, :ignored, account: account, description: "LOBLAWS IGNORED")
      bank_transaction("LOBLAWS UNFILED")

      expect(described_class.new(rule("loblaws")).count).to eq(1)
    end

    it "never count another budget's bank transactions" do
      create(:budget_bank_transaction, description: "LOBLAWS SOMEONE ELSE'S")

      expect(described_class.new(rule("loblaws")).count).to eq(0)
    end

    it "count a rule as it stands on a form, before it's saved: new, or changed" do
      bank_transaction("LOBLAWS #1")
      bank_transaction("COSTCO #1")
      saved = rule("loblaws")

      expect(described_class.new(budget.filing_rules.new(text: "costco", outcome: "ignore")).count).to eq(1)
      expect(described_class.new(saved).count).to eq(1)
      expect(described_class.new(saved.tap { |r| r.text = "costco" }).count).to eq(1)
    end

    it "count a rule that's been changed as edited now, so it beats an equal rule that was edited before, as saving it would" do
      row = bank_transaction("LOBLAWS TORONTO")
      first = rule("loblaws").tap { |r| r.update_columns(updated_at: 1.day.ago) }
      second = rule("toronto", envelope: household).tap { |r| r.update_columns(updated_at: 2.days.ago) }

      expect(described_class.new(Budget::FilingRule.find(first.id)).bank_transactions).to eq([ row ])
      expect(described_class.new(Budget::FilingRule.find(second.id)).bank_transactions).to be_empty

      changed = Budget::FilingRule.find(second.id)
      changed.envelope = groceries

      expect(described_class.new(changed).bank_transactions).to eq([ row ])
    end

    it "with `like`, leave out that bank transaction and any that went the other way, such as the one a rule is being made from" do
      this_one = bank_transaction("PAYMENT THANK YOU", amount: -250)
      same_way = bank_transaction("PAYMENT THANK YOU", amount: -30, date: Date.new(2026, 9, 14))
      other_way = bank_transaction("PAYMENT THANK YOU", amount: 250, date: Date.new(2026, 9, 13))
      payment = rule("payment thank you", :ignore)

      expect(described_class.new(payment).bank_transactions).to match_array([ this_one, same_way, other_way ])
      expect(described_class.new(payment, made_from: this_one).bank_transactions).to eq([ same_way ])
      expect(described_class.new(payment, made_from: other_way).bank_transactions).to eq([])
    end

    it "with `like`, run only files what it counts" do
      this_one = bank_transaction("PAYMENT THANK YOU", amount: -250)
      same_way = bank_transaction("PAYMENT THANK YOU", amount: -30, date: Date.new(2026, 9, 14))
      other_way = bank_transaction("PAYMENT THANK YOU", amount: 250, date: Date.new(2026, 9, 13))
      payment = rule("payment thank you", :ignore)

      expect(described_class.new(payment, made_from: this_one).run).to have_attributes(ignored: 1)

      expect(same_way.reload).to be_ignored
      expect([ this_one.reload, other_way.reload ]).to all(be_unfiled)
    end
  end
end
