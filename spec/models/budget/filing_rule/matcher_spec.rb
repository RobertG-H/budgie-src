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
    described_class.new(rules, accounts_without_filing_rules: []).rule_for(bank_transaction)
  end

  describe "the text" do
    it "is matched in any case and spacing, anywhere in the description" do
      row = bank_transaction("  LOBLAWS \t #1234   Toronto ")

      expect(winner(row, rule("loblaws"))).to be_present
      expect(winner(row, rule("LOBLAWS  TORONTO"))).to be_present
      expect(winner(row, rule("toronto"))).to be_present
      expect(winner(row, rule("oblaw"))).to be_present
      expect(winner(row, rule("blaws  toronto", account: account))).to be_present
    end

    it "has to be in the description, so another is no fit" do
      expect(winner(bank_transaction, rule("costco"))).to be_nil
      expect(winner(bank_transaction, rule("loblaws ottawa"))).to be_nil
    end

    it "is read the same way as the description is, so an unusual space or case fold can't make them disagree" do
      row = bank_transaction("B\u00E4ckerei\u00A0Stra\u00DFe 12")

      expect(winner(row, rule("stra\u00DFe"))).to be_present
      expect(winner(row, rule("B\u00C4CKEREI STRASSE"))).to be_present
      expect(winner(row, rule("b\u00E4ckerei strasse", account: account))).to be_present
    end

    it "is only text, never a pattern, so a wildcard or a regular expression is read as what it says" do
      row = bank_transaction("LOBLAWS 100% ORGANIC (TORONTO)")

      expect(winner(row, rule("lo.laws"))).to be_nil
      expect(winner(row, rule("lob[a-z]+s"))).to be_nil
      expect(winner(row, rule("loblaws organic"))).to be_present
      expect(winner(row, rule("(toronto)"))).to be_present
    end
  end

  # What changes from one bank transaction to the next isn't part of what a rule looks for, on either side (#117).
  describe "the numbers and symbols in the text and the description" do
    it "don't matter, so a rule made from one bank transaction fits the next one's, with another number" do
      made_from_one = rule("Internet Banking E-TRANSFER 106121984683 James Graham-Hu", :deposit)

      expect(winner(bank_transaction("Internet Banking E-TRANSFER 999888777 James Graham-Hu", amount: 80), made_from_one)).to eq(made_from_one)
      expect(winner(bank_transaction("Internet Banking E-TRANSFER 106121984683 Someone Else", amount: 80), made_from_one)).to be_nil
    end

    {
      "Hopp/O/2609160957" => "hopp",
      "Presto Fare/Smzxv6Sckh" => "presto fare",
      "Presto Fare/Shwqfxpddf" => "presto fare",
      "Pioneer #41051" => "pioneer",
      "Usps Po 0555550115" => "usps po",
      "Dollarama #1595" => "dollarama",
      "Loblaws #1029" => "loblaws"
    }.each do |description, text|
      it "have a rule for #{text.inspect} fit #{description.inspect}" do
        expect(winner(bank_transaction(description), rule(text))).to be_present
      end
    end

    it "fit the same rule whichever number the description has" do
      dollarama = rule("Dollarama #1595")

      expect(winner(bank_transaction("Dollarama #1673"), dollarama)).to eq(dollarama)
      expect(winner(bank_transaction("DOLLARAMA #1595 OTTAWA"), dollarama)).to eq(dollarama)
    end

    it "are not what a person can look for: a rule can't be told one store's number from another's" do
      expect(rule("dollarama #1595").text).to eq(rule("dollarama #1673", account: account).text)
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
      longer = rule("loblaws toronto", envelope: archived_envelope)
      shorter = rule("loblaws")
      archived_envelope.update!(archived_at: Time.current)

      expect(winner(bank_transaction, longer.reload, shorter)).to eq(shorter)
    end

    it "is only a rule that sets an envelope: a Deposit and Ignore have none to be archived" do
      expect(rule("loblaws", :deposit)).not_to be_inactive
      expect(rule("costco", :ignore)).not_to be_inactive
    end
  end

  # A person turns an Account's Filing rules off to review every bank transaction in it themselves, such as the ones a Splitwise expense becomes.
  describe "an Account that has Filing rules off" do
    let(:splitwise) { create(:budget_account, budget: budget, name: "Splitwise", files_with_rules: false) }

    it "has no rule win for its bank transactions, whatever fits them, and leaves the other Accounts' alone" do
      anywhere = rule("loblaws")
      mine = bank_transaction
      theirs = bank_transaction(account: splitwise)

      matcher = described_class.new([ anywhere ], accounts_without_filing_rules: [ splitwise.id ])

      expect(matcher.rule_for(mine)).to eq(anywhere)
      expect(matcher.rule_for(theirs)).to be_nil
    end

    it "makes a rule pinned to it inactive, as one for an archived envelope is, and active again once its Filing rules are on" do
      pinned = rule("loblaws", account: splitwise)
      row = bank_transaction(account: splitwise)

      expect(pinned.reload).to be_inactive
      expect(winner(row, pinned)).to be_nil

      splitwise.update!(files_with_rules: true)

      expect(pinned.reload).not_to be_inactive
      expect(winner(row, pinned)).to eq(pinned)
    end

    it "doesn't stop another Account's rules from winning, so a rule pinned to it doesn't hide a shorter one that's pinned elsewhere" do
      elsewhere = rule("loblaws", account: account)
      pinned = rule("loblaws toronto", account: splitwise)

      expect(winner(bank_transaction, pinned.reload, elsewhere)).to eq(elsewhere)
    end

    describe ".for" do
      it "asks the budget which of its Accounts have Filing rules off, and uses the budget's active rules" do
        anywhere = rule("loblaws")
        splitwise
        matcher = described_class.for(budget)

        expect(matcher.rule_for(bank_transaction)).to eq(anywhere)
        expect(matcher.rule_for(bank_transaction(account: splitwise))).to be_nil
        expect(described_class.for(create(:budget)).rule_for(bank_transaction)).to be_nil
      end

      it "uses the rules it's given instead, and leaves another budget's Accounts out of it" do
        given = rule("loblaws")
        other_budget_off = create(:budget_account, files_with_rules: false)

        matcher = described_class.for(budget, rules: [ given ])

        expect(matcher.rule_for(bank_transaction)).to eq(given)
        expect(matcher.rule_for(bank_transaction(account: other_budget_off))).to eq(given)
      end

      it "asks one question about the Accounts, whatever the rules, so what uses it makes the same number of queries for any" do
        splitwise
        given = rule("loblaws")

        expect(count_queries { described_class.for(budget, rules: []) }).to eq(1)
        expect(count_queries { described_class.for(budget, rules: [ given ]) }).to eq(1)
      end
    end
  end

  describe "when several rules fit, the most specific wins" do
    let(:row) { bank_transaction("LOBLAWS #1234 TORONTO", amount: -50) }

    it "has an exact amount beat one without, whatever else they have" do
      with_amount = rule("lob", amount: "-50")
      richer = rule("loblaws toronto", account: account)

      expect(winner(row, richer, with_amount)).to eq(with_amount)
    end

    it "then has a pinned Account beat any Account, whatever the text" do
      pinned = rule("lob", account: account)
      longer = rule("loblaws toronto")

      expect(winner(row, longer, pinned)).to eq(pinned)
    end

    it "then has longer text win" do
      short = rule("loblaws")
      long = rule("loblaws toronto")

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
      rules = [ rule("lob"), rule("loblaws"), rule("toronto", account: account), rule("toronto ", :ignore), rule("lob", amount: "-50"), rule("loblaws toronto", :ignore) ]

      winners = rules.permutation.first(200).map { |order| winner(row, *order) }.uniq

      expect(winners).to eq([ rules.find { |r| r.text == "lob" && r.amount } ])
    end
  end

  it "is nothing when no rule fits" do
    expect(winner(bank_transaction)).to be_nil
  end
end
