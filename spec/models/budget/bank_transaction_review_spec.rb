require "rails_helper"

# What a Filing rule filed or ignored is to review until a person has looked at it (ADR 0017): every way in, every way out, and what never is.
RSpec.describe Budget::BankTransaction, "to review" do
  let(:budget) { create(:budget) }
  let(:account) { create(:budget_account, budget: budget) }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  def rule(text, *traits, **attributes)
    create(:budget_filing_rule, *traits, **{ budget: budget, envelope: groceries, text: text }.merge(attributes))
  end

  # As it's read back, which is what a rule is matched against.
  def row(description = "LOBLAWS #1234", amount: -20)
    create(:budget_bank_transaction, account: account, description: description, amount: amount).reload
  end

  def apply(*rows)
    Budget::FilingRule::Applier.new(budget).apply(rows)
  end

  describe ".to_review and #to_review?" do
    it "is a bank transaction a rule filed that nobody has looked at, whichever kind of record it was filed as" do
      spend = create(:budget_bank_transaction, :filed, :by_rule, account: account)
      deposit = create(:budget_bank_transaction, :filed, :by_rule, account: account, amount: 100)

      expect(described_class.to_review).to contain_exactly(spend, deposit)
      expect([ spend, deposit ].map(&:to_review?)).to all(be(true))
    end

    it "is one a rule ignored that nobody has looked at" do
      ignored = create(:budget_bank_transaction, :ignored, :by_rule, account: account)

      expect(described_class.to_review).to contain_exactly(ignored)
      expect(ignored).to be_to_review
    end

    it "isn't one a person filed or ignored, which has no rule" do
      create(:budget_bank_transaction, :filed, account: account)
      create(:budget_bank_transaction, :ignored, account: account)

      expect(described_class.to_review).to be_empty
    end

    it "isn't one a person has looked at" do
      reviewed = create(:budget_bank_transaction, :filed, :by_rule, :reviewed, account: account)

      expect(described_class.to_review).to be_empty
      expect(reviewed).not_to be_to_review
    end

    it "isn't one that's neither filed nor ignored, though its rule went stale when its last record was deleted by hand" do
      unfiled = create(:budget_bank_transaction, :by_rule, account: account)

      expect(described_class.to_review).to be_empty
      expect(unfiled).not_to be_to_review
    end

    it "is one with several records found once" do
      split = create(:budget_bank_transaction, :by_rule, account: account, amount: -30)
      create(:budget_spend_link, bank_transaction: split, spend: create(:budget_spend, envelope: groceries, amount: 10))
      create(:budget_spend_link, bank_transaction: split, spend: create(:budget_spend, envelope: groceries, amount: 20))

      expect(described_class.to_review).to contain_exactly(split)
    end
  end

  describe "the ways in" do
    it "is an Import, which files and ignores what its rules fit, and a rule's Ignore too" do
      rule("loblaws")
      rule("payment", :ignore)
      csv_format = create(:budget_csv_format, budget: budget, name: "Plain")
      import = account.imports.build(csv_format: csv_format, file_name: "sept.csv")

      expect(import.run("2026-09-02,LOBLAWS #1234,-82.45\n2026-09-03,PAYMENT THANK YOU,-250.00\n2026-09-04,Paycheck,2800.00\n")).to be(true)

      expect(described_class.to_review.pluck(:description)).to contain_exactly("LOBLAWS #1234", "PAYMENT THANK YOU")
    end

    it "is a sweep of a rule, which files the unfiled bank transactions that are already there" do
      loblaws = rule("loblaws")
      swept = row("LOBLAWS #1")

      Budget::FilingRule::Sweep.new(loblaws).run

      expect(swept.reload).to be_to_review
    end

    it "is a rule filing a bank transaction again, after it had been reviewed and un-filed" do
      loblaws = rule("loblaws")
      first = row("LOBLAWS #1")
      apply(first)
      first.mark_reviewed
      first.unfile
      expect(first.reload).not_to be_to_review

      apply(first.reload)

      expect(first.reload).to be_to_review
      expect(first.reviewed_at).to be_nil
      expect(first.filing_rule_id).to eq(loblaws.id)
    end

    it "is a rule ignoring one again, after it had been reviewed and un-ignored" do
      rule("payment", :ignore)
      payment = row("PAYMENT THANK YOU")
      apply(payment)
      payment.mark_reviewed
      payment.unignore

      apply(payment.reload)

      expect(payment.reload).to be_to_review
    end

    it "is never what a person files with 'Always file like this': the bank transaction they filed isn't to review, though the others the rule swept are" do
      first = row("LOBLAWS #1")
      swept = row("LOBLAWS #2")
      entry = Budget::Filing::Entry.new(bank_transaction: first, drafts: [ Budget::Filing::Draft.for(first, kind: "spend", envelope_id: groceries.id) ])

      expect(Budget::FilingRule::Offer.new(first, budget: budget, text: "loblaws").file(entry)).to be(true)

      expect(first.reload).to be_filed
      expect(first).not_to be_to_review
      expect(swept.reload).to be_to_review
    end

    it "is never a person's filing" do
      first = row("LOBLAWS #1")
      entry = Budget::Filing::Entry.new(bank_transaction: first, drafts: [ Budget::Filing::Draft.for(first, kind: "spend", envelope_id: groceries.id) ])

      expect(Budget::Filing.new(budget).file([ entry ])).to be(true)

      expect(first.reload).not_to be_to_review
    end

    it "is never a person ignoring it" do
      first = row("LOBLAWS #1")

      first.ignore

      expect(first.reload).not_to be_to_review
    end
  end

  describe "the ways out" do
    let!(:loblaws) { rule("loblaws") }
    let(:filed) { row("LOBLAWS #1").tap { |bank_transaction| apply(bank_transaction) } }

    it "is Mark reviewed, which says so once" do
      expect(filed.reload).to be_to_review

      filed.mark_reviewed

      expect(filed.reload).not_to be_to_review
      expect(filed.reviewed_at).to be_within(5.seconds).of(Time.current)
      expect(filed.filing_rule_id).to eq(loblaws.id)
      expect(described_class.to_review).to be_empty
    end

    it "is refused by Mark reviewed on one that isn't to review, judged once it's locked" do
      expect { row("LOBLAWS #2").mark_reviewed }.to raise_error(described_class::Refused, "This bank transaction isn't to review.")
      filed.mark_reviewed

      expect { described_class.find(filed.id).mark_reviewed }.to raise_error(described_class::Refused)
    end

    it "is saving an edit to a Spend that was filed from it, wherever it was made" do
      filed.spend_links.sole.spend.update!(notes: "Looked at this")

      expect(filed.reload).not_to be_to_review
    end

    it "is saving an edit to a Refund or a Deposit that was filed from it" do
      refund_rule = rule("returns", :refund)
      deposit_rule = rule("paycheck", :deposit)
      refunded = row("RETURNS #1", amount: 15).tap { |bank_transaction| apply(bank_transaction) }
      deposited = row("PAYCHECK", amount: 2000).tap { |bank_transaction| apply(bank_transaction) }
      expect([ refunded.reload, deposited.reload ].map(&:to_review?)).to all(be(true))

      refunded.refund_links.sole.refund.update!(notes: "Edited")
      deposited.deposit_links.sole.deposit.update!(notes: "Edited")

      expect([ refunded.reload, deposited.reload ].map(&:to_review?)).to all(be(false))
      expect([ refund_rule, deposit_rule ]).to all(be_present)
    end

    it "isn't an edit to a record of another bank transaction" do
      other = row("LOBLAWS #2").tap { |bank_transaction| apply(bank_transaction) }
      filed

      other.spend_links.sole.spend.update!(notes: "Edited")

      expect(filed.reload).to be_to_review
      expect(other.reload).not_to be_to_review
    end

    it "isn't an edit to a record that wasn't filed from a bank transaction" do
      filed

      expect { create(:budget_spend, envelope: groceries).update!(notes: "Nothing to do with it") }.not_to raise_error
      expect(filed.reload).to be_to_review
    end

    it "is un-filing it, after which it's no longer the rule's" do
      filed.unfile

      expect(filed.reload).not_to be_to_review
      expect(filed.filing_rule_id).to be_nil
    end

    it "is un-ignoring it" do
      rule("payment", :ignore)
      ignored = row("PAYMENT THANK YOU").tap { |bank_transaction| apply(bank_transaction) }
      expect(ignored.reload).to be_to_review

      ignored.unignore

      expect(ignored.reload).not_to be_to_review
    end

    it "is deleting its record by hand, which leaves it unfiled" do
      filed.spend_links.sole.spend.destroy!

      expect(filed.reload).not_to be_to_review
    end
  end

  describe ".mark_reviewed" do
    it "marks the ones that are to review and says how many, and leaves the rest as they are" do
      first = create(:budget_bank_transaction, :filed, :by_rule, account: account)
      second = create(:budget_bank_transaction, :ignored, :by_rule, account: account)
      reviewed = create(:budget_bank_transaction, :filed, :by_rule, :reviewed, account: account)
      by_person = create(:budget_bank_transaction, :filed, account: account)

      count = described_class.mark_reviewed(described_class.where(id: [ first, second, reviewed, by_person ].map(&:id)))

      expect(count).to eq(2)
      expect([ first, second ].map { |row| row.reload.reviewed_at }).to all(be_present)
      expect(reviewed.reload.reviewed_at).to eq(Time.zone.local(2026, 9, 18, 10))
      expect(by_person.reload.reviewed_at).to be_nil
    end
  end

  it "doesn't hold up the figures, which count what a rule filed whether it was reviewed or not" do
    rule("loblaws")
    filed = row("LOBLAWS #1", amount: -20).tap { |bank_transaction| apply(bank_transaction) }

    expect(filed.reload).to be_to_review
    expect(groceries.spends.sum(:amount)).to eq(20)
  end
end
