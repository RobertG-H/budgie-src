require "rails_helper"

# A Filing rule is a standing instruction, such as "anything from Loblaws goes to Groceries". It belongs to its budget, matches on the
# description, and sets one outcome for the whole amount: a Spend from an envelope, a Refund to one, a Deposit, or Ignore.
RSpec.describe Budget::FilingRule do
  let(:budget) { create(:budget) }
  let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  def rule(**attributes)
    build(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", **attributes)
  end

  describe "its text" do
    it "is stored trimmed, with its whitespace collapsed and its case folded, as a bank transaction's description is for matching" do
      saved = create(:budget_filing_rule, budget: budget, text: "  LOBLAWS \t  Toronto\n")

      expect(saved.reload.text).to eq("loblaws toronto")
    end

    it "is stored without its numbers and symbols, which a description is read without too (#117)" do
      expect(create(:budget_filing_rule, budget: budget, text: "LOBLAWS #1234 Toronto").reload.text).to eq("loblaws toronto")
      expect(create(:budget_filing_rule, budget: budget, text: "Presto Fare/Shwqfxpddf").reload.text).to eq("presto fare")
      expect(create(:budget_filing_rule, budget: budget, text: "Internet Banking E-TRANSFER 106121984683 James Graham-Hu").reload.text).to eq("internet banking e-transfer james graham-hu")
    end

    it "is at least 3 characters once its numbers and symbols are ignored" do
      expect(rule(text: "lo")).not_to be_valid
      expect(rule(text: "lo").tap(&:valid?).errors[:text]).to eq([ "needs at least 3 characters once numbers and symbols are ignored" ])
      expect(rule(text: "   ab ")).not_to be_valid
      expect(rule(text: "#1234").tap(&:valid?).errors[:text]).to eq([ "needs at least 3 characters once numbers and symbols are ignored" ])
      expect(rule(text: "lo #1234")).not_to be_valid
      expect(rule(text: "abc")).to be_valid
    end

    it "is required" do
      expect(rule(text: nil).tap(&:valid?).errors[:text]).to eq([ "can't be blank" ])
      expect(rule(text: "  ").tap(&:valid?).errors[:text]).to eq([ "can't be blank" ])
    end

    it "is the same text as another rule's when only the numbers and symbols differ, which is refused" do
      create(:budget_filing_rule, budget: budget, text: "loblaws #1", envelope: groceries)

      duplicate = rule(text: "LOBLAWS #2")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:base].sole).to include("already has the same text, Account and amount")
    end
  end

  # What a rule saved before numbers were ignored has in its text, which the model would clean now, so it's written past it.
  def stored_before_numbers_were_ignored(rule, text)
    described_class.where(id: rule.id).update_all([ "text = ?", text ])
  end

  describe "#fits?" do
    let(:account) { create(:budget_account, budget: budget) }

    def bank_transaction(description, amount: -50)
      create(:budget_bank_transaction, account: account, description: description, amount: amount).reload
    end

    it "fits a description that differs from the one the rule was made from only by its number" do
      loblaws = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "LOBLAWS #1234")

      expect(loblaws.text).to eq("loblaws")
      expect(loblaws.fits?(bank_transaction("Loblaws #1029"))).to be(true)
      expect(loblaws.fits?(bank_transaction("LOBLAWS 77 TORONTO ON"))).to be(true)
      expect(loblaws.fits?(bank_transaction("Costco #1029"))).to be(false)
    end

    it "fits every e-transfer from one person whatever its number, and not another person's" do
      etransfer = create(:budget_filing_rule, budget: budget, outcome: "deposit", envelope: nil, text: "Internet Banking E-TRANSFER 106121984683 James Graham-Hu")

      expect(etransfer.fits?(bank_transaction("Internet Banking E-TRANSFER 999 James Graham-Hu", amount: 80))).to be(true)
      expect(etransfer.fits?(bank_transaction("Internet Banking E-TRANSFER 106121984683 Someone Else", amount: 80))).to be(false)
    end

    it "reads the text it matches the way it's saved, so a rule saved before the numbers were ignored still fits" do
      old = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      stored_before_numbers_were_ignored(old, "loblaws #1234")

      expect(old.reload.text).to eq("loblaws #1234")
      expect(old.fits?(bank_transaction("Loblaws #1029"))).to be(true)
      expect(old.fits?(bank_transaction("Costco #1029"))).to be(false)
    end
  end

  describe "#specificity" do
    it "goes by the text without its numbers and symbols" do
      old = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      stored_before_numbers_were_ignored(old, "loblaws #1234 #5678")

      expect(old.reload.specificity.third).to eq("loblaws".length)
    end
  end

  describe "its outcome" do
    it "is a Spend, a Refund, a Deposit or Ignore" do
      expect(%w[ spend refund deposit ignore ].map { |outcome| rule(outcome: outcome).tap(&:valid?).errors[:outcome] }).to all(be_empty)
      expect(rule(outcome: "reallocate").tap(&:valid?).errors[:outcome]).to eq([ "is not included in the list" ])
      expect(rule(outcome: nil).tap(&:valid?).errors[:outcome]).to eq([ "can't be blank" ])
    end

    it "needs an envelope for a Spend or a Refund, which is how they're told from a Deposit" do
      expect(rule(outcome: "spend", envelope: nil).tap(&:valid?).errors[:envelope]).to eq([ "can't be blank" ])
      expect(rule(outcome: "refund", envelope: nil).tap(&:valid?).errors[:envelope]).to eq([ "can't be blank" ])
    end

    it "has no envelope for a Deposit or Ignore, so one that's sent is left out" do
      %w[ deposit ignore ].each do |outcome|
        deposit = rule(outcome: outcome, envelope: groceries)

        expect(deposit).to be_valid
        expect(deposit.envelope).to be_nil
      end
    end
  end

  describe "its amount" do
    it "is optional, and any amount at all when it's not there" do
      expect(rule(amount: nil)).to be_valid
      expect(rule(amount: "").amount).to be_nil
    end

    it "is signed, with money out negative, and never 0" do
      expect(rule(outcome: "ignore", amount: "-82.45")).to be_valid
      expect(rule(outcome: "ignore", amount: "82.45")).to be_valid
      expect(rule(outcome: "ignore", amount: "0").tap(&:valid?).errors[:amount]).to eq([ "must be other than 0" ])
    end

    it "follows the core's money rule: at most 2 decimal places, which is refused and never rounded, and under 10**13" do
      expect(rule(outcome: "ignore", amount: "1.005").tap(&:valid?).errors[:amount]).to eq([ "can't have more than 2 decimal places" ])
      expect(rule(outcome: "ignore", amount: 10**13).tap(&:valid?).errors[:amount]).not_to be_empty
      expect(rule(outcome: "ignore", amount: "abc").tap(&:valid?).errors[:amount]).not_to be_empty
    end

    it "is negative for a Spend, which is money out" do
      expect(rule(outcome: "spend", amount: "-10")).to be_valid
      expect(rule(outcome: "spend", amount: "10").tap(&:valid?).errors[:amount]).to eq([ "must be negative, since a Spend is money out" ])
    end

    it "is positive for a Refund or a Deposit, which are money in" do
      expect(rule(outcome: "refund", amount: "10")).to be_valid
      expect(rule(outcome: "refund", amount: "-10").tap(&:valid?).errors[:amount]).to eq([ "must be positive, since a Refund is money in" ])
      expect(rule(outcome: "deposit", amount: "10")).to be_valid
      expect(rule(outcome: "deposit", amount: "-10").tap(&:valid?).errors[:amount]).to eq([ "must be positive, since a Deposit is money in" ])
    end
  end

  describe "its Account and envelope" do
    it "can't be another budget's, which is an error on the field" do
      others_account = create(:budget_account)
      others_envelope = create(:budget_envelope)

      expect(rule(account: others_account).tap(&:valid?).errors[:account]).to eq([ "isn't one of this budget's" ])
      expect(rule(envelope: others_envelope).tap(&:valid?).errors[:envelope]).to eq([ "isn't one of this budget's" ])
    end

    it "can't be one that doesn't exist" do
      expect(rule(account_id: 0).tap(&:valid?).errors[:account]).to eq([ "isn't one of this budget's" ])
      expect(rule(envelope_id: 0).tap(&:valid?).errors[:envelope]).to eq([ "isn't one of this budget's" ])
    end

    it "can be the budget's own Account, which is an extra condition" do
      account = create(:budget_account, budget: budget)

      expect(rule(account: account)).to be_valid
    end

    it "refuses an archived envelope when the rule is new or moves to it, but not for a rule that's already in one" do
      archived = create(:budget_envelope, budget: budget, name: "Old", archived_at: Time.current)

      expect(rule(envelope: archived).tap(&:valid?).errors[:envelope]).to eq([ "is archived" ])

      saved = create(:budget_filing_rule, budget: budget, envelope: groceries)
      expect(saved.tap { |r| r.envelope = archived }.tap(&:valid?).errors[:envelope]).to eq([ "is archived" ])

      in_archived = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco")
      groceries.update!(archived_at: Time.current)
      expect(in_archived.reload.tap { |r| r.text = "costco wholesale" }).to be_valid
    end
  end

  describe "its conditions" do
    it "are unique in a budget: the same text, Account and amount is an error that says what the other rule does" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      duplicate = rule(outcome: "ignore")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors.full_messages).to eq([ "Another Filing rule already has the same text, Account and amount. It files them as Spend from Groceries." ])
    end

    it "say which Account when the other rule is for one, as the filing form's update line does" do
      account = create(:budget_account, budget: budget, name: "Chequing")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: account)

      duplicate = rule(outcome: "ignore", account: account)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors.full_messages).to eq([ "Another Filing rule for 'loblaws' in Chequing already has the same text, Account and amount. It files them as Spend from Groceries." ])
    end

    it "differ by Account or by amount, and another budget's rules don't count" do
      account = create(:budget_account, budget: budget)
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      expect(rule(account: account)).to be_valid
      expect(rule(amount: "-10")).to be_valid
      expect(create(:budget_filing_rule, text: "loblaws")).to be_valid
    end

    it "aren't a duplicate of the rule itself when it's saved again" do
      saved = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      expect(saved.tap { |r| r.outcome = "ignore" }).to be_valid
    end
  end

  describe "what it says it does" do
    it "is a phrase to follow 'it': what it files them as, or that it ignores them" do
      expect(rule(outcome: "spend").effect).to eq("files them as Spend from Groceries")
      expect(rule(outcome: "deposit").effect).to eq("files them as Deposit")
      expect(rule(outcome: "ignore").effect).to eq("ignores them")
    end

    it "is a Spend from an envelope, a Refund to one, a Deposit, or Ignore" do
      expect(rule(outcome: "spend").outcome_label).to eq("Spend from Groceries")
      expect(rule(outcome: "refund").outcome_label).to eq("Refund to Groceries")
      expect(rule(outcome: "deposit").outcome_label).to eq("Deposit")
      expect(rule(outcome: "ignore").outcome_label).to eq("Ignore")
    end
  end

  describe "#save_and_sweep" do
    let(:account) { create(:budget_account, budget: budget) }

    it "saves the rule, and files the unfiled bank transactions it now fits when asked to, saying what it did" do
      row = create(:budget_bank_transaction, account: account, description: "LOBLAWS #1", amount: -20)
      loblaws = rule

      expect(loblaws.save_and_sweep(sweep: true)).to be(true)

      expect(loblaws).to be_persisted
      expect(loblaws.swept).to have_attributes(filed: 1, ignored: 0)
      expect(row.reload.filing_rule_id).to eq(loblaws.id)
    end

    it "saves it and sweeps nothing when not asked to" do
      row = create(:budget_bank_transaction, account: account, description: "LOBLAWS #1", amount: -20)
      loblaws = rule

      expect(loblaws.save_and_sweep).to be(true)

      expect(loblaws.swept).to be_nil
      expect(row.reload).to be_unfiled
    end

    it "saves and sweeps nothing for a rule that's refused, which says why" do
      create(:budget_bank_transaction, account: account, description: "LOBLAWS #1", amount: -20)

      expect(rule(text: "lo").save_and_sweep(sweep: true)).to be(false)

      expect(Budget::FilingRule.count).to eq(0)
      expect(Budget::Spend.count).to eq(0)
    end

    it "is one database transaction, so a failure in the sweep leaves no rule" do
      create(:budget_bank_transaction, account: account, description: "LOBLAWS #1", amount: -20)
      allow_any_instance_of(Budget::FilingRule::Sweep).to receive(:run).and_raise(ActiveRecord::StatementInvalid, "the database went away")

      expect { rule.save_and_sweep(sweep: true) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(Budget::FilingRule.count).to eq(0)
    end

    it "says so, and not with an error page, when a rule with the same conditions was saved a moment ago, which only the unique index sees" do
      loblaws = rule
      allow(loblaws).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      expect(loblaws.save_and_sweep(sweep: true)).to be(false)

      expect(loblaws.errors.full_messages).to eq([ "Another Filing rule with the same text, Account and amount was saved a moment ago. Try again." ])
    end
  end

  describe "in the database" do
    # Saved with its validations skipped, so that it's the table's constraints that refuse it. In a savepoint of its own, since a refused
    # statement ends the transaction it's in, and the spec's goes on.
    def insert(**attributes)
      Budget::FilingRule.transaction(requires_new: true) { rule(**attributes).save(validate: false) }
    end

    it "refuses text under 3 characters" do
      expect { insert(text: "lo") }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_text_at_least_3_characters/)
      expect { insert(text: "   ") }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_text_at_least_3_characters/)
    end

    it "refuses two rules with the same text and no Account and no amount, since nulls count as the same" do
      insert

      expect { insert(outcome: "ignore", envelope: nil) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same text with a different Account or amount" do
      insert
      account = create(:budget_account, budget: budget)

      expect { insert(account: account) }.not_to raise_error
      expect { insert(amount: -5) }.not_to raise_error
      expect { insert(account: account, amount: -5) }.not_to raise_error
      expect { insert(account: account, amount: -5, outcome: "ignore", envelope: nil) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "refuses an amount of 0" do
      expect { insert(outcome: "ignore", amount: 0) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_amount_not_zero/)
    end

    it "refuses a Spend with a positive amount, and a Refund or Deposit with a negative one" do
      expect { insert(outcome: "spend", amount: 5) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_amount_suits_outcome/)
      expect { insert(outcome: "refund", amount: -5) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_amount_suits_outcome/)
      expect { insert(outcome: "deposit", envelope: nil, amount: -5) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_amount_suits_outcome/)
    end

    it "takes either sign for Ignore" do
      expect { insert(outcome: "ignore", envelope: nil, amount: 5) }.not_to raise_error
      expect { insert(outcome: "ignore", envelope: nil, text: "other", amount: -5) }.not_to raise_error
    end

    it "refuses a Spend or a Refund without an envelope, and a Deposit or Ignore with one" do
      expect { insert(outcome: "spend", envelope: nil) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_envelope_for_outcome/)
      expect { insert(outcome: "refund", envelope: nil) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_envelope_for_outcome/)
      expect { insert(outcome: "deposit", envelope: groceries) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_envelope_for_outcome/)
      expect { insert(outcome: "ignore", envelope: groceries) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_envelope_for_outcome/)
    end

    it "refuses an outcome it doesn't know" do
      expect { insert(outcome: "reallocate", envelope: nil) }.to raise_error(ActiveRecord::StatementInvalid, /budget_filing_rules_outcome_known/)
    end

    it "keeps its envelope, its Account and its budget from being deleted from under it" do
      saved = create(:budget_filing_rule, budget: budget, envelope: groceries, account: create(:budget_account, budget: budget))

      [ Budget::Envelope.where(id: saved.envelope_id), Budget::Account.where(id: saved.account_id), Budget.where(id: budget.id) ].each do |records|
        expect { Budget::FilingRule.transaction(requires_new: true) { records.delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
      end
    end
  end

  describe "the bank transactions it filed" do
    it "are left alone, with no rule, when it's deleted" do
      saved = create(:budget_filing_rule, budget: budget, envelope: groceries)
      account = create(:budget_account, budget: budget)
      bank_transaction = create(:budget_bank_transaction, :filed, account: account)
      bank_transaction.update_columns(filing_rule_id: saved.id)

      saved.destroy!

      expect(bank_transaction.reload.filing_rule_id).to be_nil
      expect(bank_transaction).to be_filed
    end

    it "keeps the table from losing a rule that a bank transaction names" do
      saved = create(:budget_filing_rule, budget: budget, envelope: groceries)
      bank_transaction = create(:budget_bank_transaction, account: create(:budget_account, budget: budget))
      bank_transaction.update_columns(filing_rule_id: saved.id)

      expect { Budget::FilingRule.where(id: saved.id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
