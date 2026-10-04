require "rails_helper"

# Which Filing rule a bank transaction fits, when more than one does: the most specific wins (#69), and there's no ordering screen.
RSpec.describe Budget::FilingRule::Matcher do
  let(:budget) { create(:budget) }
  let(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  # As it's read back, which is what a rule is matched against: the database works out the normalised description.
  def bank_transaction(description = "LOBLAWS #1234 TORONTO", amount: -50, account: self.account)
    create(:budget_bank_transaction, account: account, description: description, amount: amount).reload
  end

  # A Spend from Groceries unless it's given another outcome as a trait.
  def rule(text, *traits, **attributes)
    create(:budget_filing_rule, *traits, **{ budget: budget, envelope: groceries, text: text }.merge(attributes))
  end

  def winner(bank_transaction, *rules)
    described_class.new(rules).rule_for(bank_transaction)
  end

  describe "the text" do
    it "is matched in any case and spacing, anywhere in the description" do
      row = bank_transaction("  LOBLAWS \t #1234   Toronto ")

      expect(winner(row, rule("loblaws"))).to be_present
      expect(winner(row, rule("LOBLAWS  #1234"))).to be_present
      expect(winner(row, rule("1234 toronto"))).to be_present
      expect(winner(row, rule("oblaw"))).to be_present
      expect(winner(row, rule("loblaws #1234 toronto"))).to be_present
    end

    it "has to be in the description, so another is no fit" do
      expect(winner(bank_transaction, rule("costco"))).to be_nil
      expect(winner(bank_transaction, rule("loblaws toronto"))).to be_nil
    end

    it "is only text, never a pattern, so a wildcard or a regular expression is read as what it says" do
      row = bank_transaction("LOBLAWS 100% ORGANIC (TORONTO)")

      expect(winner(row, rule("loblaws.*"))).to be_nil
      expect(winner(row, rule("%%%"))).to be_nil
      expect(winner(row, rule("loblaws_100"))).to be_nil
      expect(winner(row, rule("100% organic"))).to be_present
      expect(winner(row, rule("(toronto)"))).to be_present
    end
  end

  describe "the Account" do
    it "fits only a bank transaction in it, when the rule has one, and any Account when it hasn't" do
      savings = create(:budget_account, budget: budget, name: "Savings")
      pinned = rule("loblaws", account: account)

      expect(winner(bank_transaction(account: account), pinned)).to eq(pinned)
      expect(winner(bank_transaction(account: savings), pinned)).to be_nil
      expect(winner(bank_transaction(account: savings), rule("loblaws"))).to be_present
    end
  end

  describe "the amount" do
    it "has to be the bank transaction's exactly, with its sign, when the rule has one" do
      exact = rule("loblaws", amount: "-50.00")

      expect(winner(bank_transaction(amount: -50), exact)).to eq(exact)
      expect(winner(bank_transaction(amount: "-50.01"), exact)).to be_nil
      expect(winner(bank_transaction(amount: -49), exact)).to be_nil
      expect(winner(bank_transaction(amount: 50), rule("lobla", :ignore, amount: "-50.00"))).to be_nil
    end

    it "is any amount when the rule has none" do
      expect(winner(bank_transaction(amount: -1234.56), rule("loblaws"))).to be_present
    end
  end

  describe "the sign" do
    it "suits the outcome: a Spend fits money out, a Refund and a Deposit fit money in, and Ignore fits either" do
      money_out = bank_transaction(amount: -50)
      money_in = bank_transaction(amount: 50)
      spend = rule("loblaws")
      refund = rule("loblaw", :refund)
      deposit = rule("lobla", :deposit)
      ignore = rule("obla", :ignore)

      expect(winner(money_out, spend)).to eq(spend)
      expect(winner(money_in, spend)).to be_nil
      expect(winner(money_in, refund)).to eq(refund)
      expect(winner(money_out, refund)).to be_nil
      expect(winner(money_in, deposit)).to eq(deposit)
      expect(winner(money_out, deposit)).to be_nil
      expect(winner(money_out, ignore)).to eq(ignore)
      expect(winner(money_in, ignore)).to eq(ignore)
    end
  end

  describe "a rule for an archived envelope" do
    it "is skipped as if it didn't exist, and fits again once the envelope is unarchived" do
      row = bank_transaction
      archived = rule("loblaws")
      groceries.update!(archived_at: Time.current)

      expect(winner(row, archived.reload)).to be_nil
      expect(archived.reload).to be_inactive

      groceries.update!(archived_at: nil)

      expect(winner(row, archived.reload)).to eq(archived)
    end

    it "doesn't stop the rules that aren't archived from winning" do
      archived_envelope = create(:budget_envelope, budget: budget, name: "Old", archived_at: nil)
      longer = rule("loblaws #1234", envelope: archived_envelope)
      shorter = rule("loblaws")
      archived_envelope.update!(archived_at: Time.current)

      expect(winner(bank_transaction, longer.reload, shorter)).to eq(shorter)
    end

    it "is only a rule that sets an envelope: a Deposit and Ignore have none to be archived" do
      expect(rule("loblaws", :deposit)).not_to be_inactive
      expect(rule("costco", :ignore)).not_to be_inactive
    end
  end

  describe "when several rules fit, the most specific wins" do
    let(:row) { bank_transaction("LOBLAWS #1234 TORONTO", amount: -50) }

    it "has an exact amount beat one without, whatever else they have" do
      with_amount = rule("lob", amount: "-50")
      richer = rule("loblaws #1234 toronto", account: account)

      expect(winner(row, richer, with_amount)).to eq(with_amount)
    end

    it "then has a pinned Account beat any Account, whatever the text" do
      pinned = rule("lob", account: account)
      longer = rule("loblaws #1234 toronto")

      expect(winner(row, longer, pinned)).to eq(pinned)
    end

    it "then has longer text win" do
      short = rule("loblaws")
      long = rule("loblaws #1234")

      expect(winner(row, short, long)).to eq(long)
    end

    it "then has the most recently edited win" do
      older = rule("loblaws").tap { |r| r.update_columns(updated_at: 2.days.ago) }
      newer = rule("toronto").tap { |r| r.update_columns(updated_at: 1.day.ago) }

      expect(older.text.length).to eq(newer.text.length)
      expect(winner(row, older, newer)).to eq(newer)

      older.update_columns(updated_at: Time.current)
      expect(winner(row, older, newer)).to eq(older)
    end

    it "then has the newer rule win, so that the order is total" do
      first = rule("loblaws")
      second = rule("toronto")
      moment = Time.zone.local(2026, 10, 1, 12)
      [ first, second ].each { |r| r.update_columns(updated_at: moment) }

      expect(first.text.length).to eq(second.text.length)
      expect(winner(row, first, second)).to eq(second)
      expect(winner(row, second, first)).to eq(second)
    end

    it "gives the same winner whichever order the rules come in" do
      rules = [ rule("lob"), rule("loblaws"), rule("toronto", account: account), rule("#1234 t"), rule("1234", amount: "-50"), rule("loblaws #1234", :ignore) ]

      winners = rules.permutation.first(200).map { |order| winner(row, *order) }.uniq

      expect(winners).to eq([ rules.find { |r| r.text == "1234" } ])
    end
  end

  it "is nothing when no rule fits" do
    expect(winner(bank_transaction)).to be_nil
  end
end
