require "rails_helper"

RSpec.describe Budget::FilingRule::Offer do
  let(:budget) { create(:budget) }
  let(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let(:savings) { create(:budget_account, budget: budget, name: "Savings") }
  let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:loblaws) { create(:budget_bank_transaction, account: chequing, description: "LOBLAWS #1234", date: Date.new(2026, 9, 12), amount: -50) }

  def offer(**attributes)
    described_class.new(loblaws, budget: budget, text: "loblaws", **attributes)
  end

  def entry
    Budget::Filing::Entry.new(bank_transaction: loblaws, drafts: [ Budget::Filing::Draft.for(loblaws, kind: "spend", envelope_id: groceries.id, amount: 50) ])
  end

  describe "its Account" do
    it "starts as the bank transaction's own" do
      expect(offer.account_id).to eq(chequing.id)
      expect(described_class.new(loblaws, budget: budget).account_id).to eq(chequing.id)
    end

    it "is none, which is any Account, when it's told so" do
      expect(offer(account_id: nil).account_id).to be_nil
      expect(offer(account_id: "").account_id).to be_nil
    end

    it "is the bank transaction's own when it's told its id, as the form's radio sends it" do
      expect(offer(account_id: chequing.id.to_s).account_id).to eq(chequing.id)
    end

    it "is the bank transaction's own for anything else, since a rule for another Account wouldn't fit the bank transaction it's made from" do
      expect(offer(account_id: savings.id).account_id).to eq(chequing.id)
      expect(offer(account_id: "999999").account_id).to eq(chequing.id)
      expect(offer(account_id: "nonsense").account_id).to eq(chequing.id)
      expect(offer(account_id: create(:budget_account).id).account_id).to eq(chequing.id)
    end

    it "makes a rule for the bank transaction's Account by default, with no amount" do
      expect(offer.file(entry)).to be(true)

      expect(budget.filing_rules.sole).to have_attributes(text: "loblaws", account_id: chequing.id, amount: nil, outcome: "spend", envelope_id: groceries.id)
    end

    it "makes a rule for any Account when that's chosen" do
      expect(offer(account_id: nil).file(entry)).to be(true)

      expect(budget.filing_rules.sole).to have_attributes(text: "loblaws", account_id: nil, amount: nil)
    end

    it "makes an Ignore rule for the Account when it ignores" do
      expect(offer.ignore).to be(true)

      expect(loblaws.reload).to be_ignored
      expect(budget.filing_rules.sole).to have_attributes(text: "loblaws", account_id: chequing.id, outcome: "ignore", envelope_id: nil)
    end
  end

  describe "#existing_rule" do
    it "is the rule with the same text and Account, and no amount" do
      pinned = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: chequing)

      expect(offer.existing_rule).to eq(pinned)
    end

    it "is not a rule for any Account when the offer is for the Account, nor one for the Account when it's for any" do
      anywhere = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      pinned = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: chequing)

      expect(offer.existing_rule).to eq(pinned)
      expect(offer(account_id: nil).existing_rule).to eq(anywhere)
    end

    it "is not another Account's rule, nor one with an amount" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: savings)
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: chequing, amount: -50)

      expect(offer.existing_rule).to be_nil
    end
  end

  describe "a rule for the Account and one for any Account with the same text" do
    it "don't update each other: they're different rules, as the unique index says" do
      anywhere = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      expect { offer.file(entry) }.to change(budget.filing_rules, :count).by(1)

      expect(anywhere.reload).to have_attributes(account_id: nil, outcome: "spend")
      expect(budget.filing_rules.where.not(id: anywhere.id).sole).to have_attributes(account_id: chequing.id)
    end

    it "and a pinned rule that's there is updated in place by a pinned offer, not made twice" do
      household = create(:budget_envelope, budget: budget, name: "Household")
      pinned = create(:budget_filing_rule, budget: budget, envelope: household, text: "loblaws", account: chequing)

      expect { expect(offer.file(entry)).to be(true) }.not_to change(budget.filing_rules, :count)

      expect(pinned.reload).to have_attributes(envelope_id: groceries.id, account_id: chequing.id)
    end

    it "and an Ignore turns a pinned Spend rule into an Ignore rule, dropping its envelope" do
      pinned = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: chequing)

      offer.ignore

      expect(pinned.reload).to have_attributes(outcome: "ignore", envelope_id: nil, account_id: chequing.id)
    end
  end

  describe "the sweep" do
    let!(:here) { create(:budget_bank_transaction, account: chequing, description: "LOBLAWS #99", date: Date.new(2026, 9, 14), amount: -20) }
    let!(:there) { create(:budget_bank_transaction, account: savings, description: "LOBLAWS #77", date: Date.new(2026, 9, 15), amount: -30) }

    it "of a rule for the Account counts and files only that Account's unfiled bank transactions" do
      expect(offer.sweep_preview.count).to eq(1)
      expect(offer.sweep_preview.bank_transactions).to eq([ here.reload ])

      expect(offer(sweep: true).file(entry)).to be(true)

      expect(here.reload).to be_filed
      expect(there.reload).to be_unfiled
    end

    it "of a rule for any Account counts and files them all" do
      expect(offer(account_id: nil).sweep_preview.count).to eq(2)

      subject = offer(account_id: nil, sweep: true)
      expect(subject.file(entry)).to be(true)

      expect(here.reload).to be_filed
      expect(there.reload).to be_filed
      expect(subject.swept.filed).to eq(2)
    end

    it "doesn't change an existing rule while it only previews it" do
      household = create(:budget_envelope, budget: budget, name: "Household")
      pinned = create(:budget_filing_rule, budget: budget, envelope: household, text: "loblaws", account: chequing)

      expect(offer.sweep_preview.count).to eq(1)
      expect(pinned.reload.outcome).to eq("spend")
    end
  end

  describe "#needs_attention?" do
    it "isn't for the rule as offered" do
      expect(offer(text: nil)).not_to be_needs_attention
    end

    it "is for a text that isn't the bank's own, for an error, and for a rule that it would update" do
      expect(offer(text: "lob")).to be_needs_attention

      refused = offer(text: "shell")
      expect(refused.file(entry)).to be(false)
      expect(refused).to be_needs_attention

      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws #1234", account: chequing)
      expect(offer(text: nil)).to be_needs_attention
    end
  end
end
