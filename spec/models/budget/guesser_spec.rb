require "rails_helper"

# A Guess is what Budgie proposes for an unfiled bank transaction that no active Filing rule fits: the kind and envelope it was most like,
# judging by how the Budget's own filed bank transactions were filed (ADR 0013). It only suggests, never stores anything, and never
# proposes Ignore or an archived envelope.
RSpec.describe Budget::Guesser do
  include FilingHistory

  let(:budget) { create(:budget) }
  let(:account) { create(:budget_account, budget: budget) }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

  def guess(bank_transaction)
    described_class.new(budget).guess(bank_transaction)
  end

  describe "#guess" do
    it "is the kind and envelope that a similar bank transaction was filed as, saying which one it was like" do
      filed("LOBLAWS #1234", groceries)

      guess = guess(unfiled("LOBLAWS #5678"))

      expect(guess).to have_attributes(kind: "spend", envelope_id: groceries.id, envelope_name: "Groceries", like: "LOBLAWS #1234")
      expect(guess.label).to eq("Guess: like LOBLAWS #1234 → Groceries")
    end

    it "reads a description the way a Filing rule does, whatever its case or spacing, and ignores store numbers and reference codes" do
      filed("Amzn  Mktp CA*1A2B3C4D5", household)

      expect(guess(unfiled("AMZN MKTP CA*9Z8Y7X6W5"))).to have_attributes(envelope_id: household.id, like: "Amzn  Mktp CA*1A2B3C4D5")
    end

    it "is nothing for a merchant the Budget has never filed" do
      filed("LOBLAWS #1234", groceries)

      expect(guess(unfiled("SHELL OIL #55"))).to be_nil
    end

    it "is nothing when the Budget has filed nothing at all" do
      expect(guess(unfiled("LOBLAWS #5678"))).to be_nil
    end

    it "creates and changes nothing, however sure it is" do
      filed("LOBLAWS #1234", groceries)
      row = unfiled("LOBLAWS #5678")

      expect { guess(row) }.not_to change { [ Budget::BankTransaction.count, Budget::Spend.count, Budget::SpendLink.count, Budget::FilingRule.count, row.reload.attributes ] }
      expect(row).to be_unfiled
    end

    describe "money in" do
      it "is a Deposit, which has no envelope, when similar money in was filed as one" do
        filed("ACME PAYROLL SEP", amount: 2800)

        guess = guess(unfiled("ACME PAYROLL OCT", amount: 2800))

        expect(guess).to have_attributes(kind: "deposit", envelope_id: nil, envelope_name: nil, like: "ACME PAYROLL SEP")
        expect(guess.label).to eq("Guess: like ACME PAYROLL SEP → Deposit")
      end

      it "is a Refund to an envelope when similar money in was filed as one" do
        filed("LOBLAWS RETURN", groceries, amount: 18.75)

        guess = guess(unfiled("LOBLAWS RETURN #88", amount: 9.5))

        expect(guess).to have_attributes(kind: "refund", envelope_id: groceries.id)
        expect(guess.label).to eq("Guess: like LOBLAWS RETURN → Refund to Groceries")
      end

      it "isn't worked out from money-out history, and money out isn't from money-in history" do
        filed("LOBLAWS #1234", groceries, amount: -50)
        filed("ACME PAYROLL SEP", amount: 2800)

        expect(guess(unfiled("LOBLAWS #5678", amount: 20))).to be_nil
        expect(guess(unfiled("ACME PAYROLL OCT", amount: -20))).to be_nil
      end
    end

    describe "which history counts" do
      it "leaves out ignored bank transactions, since a Guess never proposes Ignore" do
        create(:budget_bank_transaction, :ignored, account: account, description: "LOBLAWS #1234")

        expect(guess(unfiled("LOBLAWS #5678"))).to be_nil
      end

      it "leaves out history filed into an archived envelope, so one in use is proposed instead, or none" do
        old = create(:budget_envelope, budget: budget, name: "Old groceries")
        filed("LOBLAWS #1234", old)
        filed("LOBLAWS #2345", old)
        old.update!(archived_at: Time.current)

        expect(guess(unfiled("LOBLAWS #5678"))).to be_nil

        filed("LOBLAWS #3456", groceries)

        expect(guess(unfiled("LOBLAWS #6789"))).to have_attributes(envelope_id: groceries.id, like: "LOBLAWS #3456")
      end

      it "leaves out a bank transaction that was split, since its records are in different envelopes" do
        split = create(:budget_bank_transaction, account: account, description: "COSTCO #12", amount: -100)
        create(:budget_spend_link, bank_transaction: split, spend: create(:budget_spend, envelope: groceries, amount: 60))
        create(:budget_spend_link, bank_transaction: split, spend: create(:budget_spend, envelope: household, amount: 40))

        expect(guess(unfiled("COSTCO #99"))).to be_nil
      end

      it "leaves out a bank transaction that isn't filed" do
        unfiled("LOBLAWS #1234")

        expect(guess(unfiled("LOBLAWS #5678"))).to be_nil
      end

      it "counts bank transactions from every Account in the Budget, and none from another Budget" do
        other_account = create(:budget_account, budget: budget)
        filed("LOBLAWS #1234", groceries, account: other_account)
        create(:budget_bank_transaction, :filed, description: "SHELL OIL #55")

        expect(guess(unfiled("LOBLAWS #5678"))).to have_attributes(envelope_id: groceries.id)
        expect(guess(unfiled("SHELL OIL #66"))).to be_nil
      end

      it "reads the record as it is now, so moving it to another envelope changes the next Guess" do
        row = filed("LOBLAWS #1234", groceries)
        expect(guess(unfiled("LOBLAWS #5678"))).to have_attributes(envelope_id: groceries.id)

        row.spend_links.sole.spend.update!(envelope: household)

        expect(guess(unfiled("LOBLAWS #5678"))).to have_attributes(envelope_id: household.id, envelope_name: "Household")
      end

      it "goes by the bank's description, not the description a person gave the record" do
        row = filed("LOBLAWS #1234", groceries)
        row.spend_links.sole.spend.update!(description: "Weekly shop")

        expect(guess(unfiled("LOBLAWS #5678"))).to have_attributes(like: "LOBLAWS #1234")
        expect(guess(unfiled("WEEKLY SHOP"))).to be_nil
      end

      it "is nothing once the record is deleted, which leaves the bank transaction unfiled" do
        row = filed("LOBLAWS #1234", groceries)
        row.spend_links.sole.spend.destroy!

        expect(guess(unfiled("LOBLAWS #5678"))).to be_nil
      end
    end

    describe "how alike it has to be" do
      it "is nothing below the threshold, however much of the description is shared" do
        filed("TIM HORTONS DOWNTOWN", groceries)

        expect(guess(unfiled("TIM HORTONS AIRPORT TERMINAL"))).to be_nil
        expect(guess(unfiled("TIM HORTONS #4321 QPS"))).to have_attributes(envelope_id: groceries.id)
      end

      it "counts a word less the more envelopes it has been filed in, so boilerplate doesn't make two merchants alike" do
        rogers = create(:budget_envelope, budget: budget, name: "Phone")
        hydro = create(:budget_envelope, budget: budget, name: "Hydro")
        filed("PRE-AUTHORIZED PAYMENT ROGERS", rogers)
        filed("PRE-AUTHORIZED PAYMENT HYDRO ONE", hydro)
        filed("PRE-AUTHORIZED PAYMENT GYM", household)

        expect(guess(unfiled("PRE-AUTHORIZED PAYMENT ROGERS"))).to have_attributes(envelope_id: rogers.id)
        expect(guess(unfiled("PRE-AUTHORIZED PAYMENT HYDRO ONE"))).to have_attributes(envelope_id: hydro.id)
        expect(guess(unfiled("PRE-AUTHORIZED PAYMENT INSURANCE"))).to be_nil
      end

      it "weighs a word by history of the same sign only, so money in doesn't make a merchant's money out less sure" do
        filed("COSTCO #1", household)
        filed("COSTCO RETURN", groceries, amount: 18.75)
        filed("COSTCO REBATE", amount: 5)

        expect(guess(unfiled("COSTCO TORONTO"))).to have_attributes(kind: "spend", envelope_id: household.id, like: "COSTCO #1")
      end

      it "is nothing for a description with no words in it" do
        filed("LOBLAWS #1234", groceries)

        expect(guess(unfiled("*** ###"))).to be_nil
      end

      it "goes by the whole description when it's only numbers" do
        filed("20250915 0099", household)

        expect(guess(unfiled("20250915 0099"))).to have_attributes(envelope_id: household.id)
        expect(guess(unfiled("20250916 0099"))).to be_nil
      end
    end

    describe "when more than one thing is alike" do
      it "goes with the most alike" do
        filed("LOBLAWS PHARMACY #9", household)
        filed("LOBLAWS #1234", groceries)

        expect(guess(unfiled("LOBLAWS #5678"))).to have_attributes(envelope_id: groceries.id, like: "LOBLAWS #1234")
        expect(guess(unfiled("LOBLAWS PHARMACY #77"))).to have_attributes(envelope_id: household.id)
      end

      it "goes with what it was filed as most often when they're equally alike, and then with the most recent" do
        filed("COSTCO #1", household, date: Date.new(2026, 9, 28))
        2.times { |n| filed("COSTCO #2#{n}", groceries, date: Date.new(2026, 9, 1 + n)) }

        expect(guess(unfiled("COSTCO #99"))).to have_attributes(envelope_id: groceries.id)

        filed("COSTCO #3", household, date: Date.new(2026, 9, 29))

        expect(guess(unfiled("COSTCO #99"))).to have_attributes(envelope_id: household.id, like: "COSTCO #3")
      end

      it "goes with the most recently filed when everything else is the same, so it's never a toss-up" do
        filed("COSTCO #1", groceries, date: Date.new(2026, 9, 5))
        filed("COSTCO #2", household, date: Date.new(2026, 9, 5))

        expect(guess(unfiled("COSTCO #99"))).to have_attributes(envelope_id: household.id)
      end
    end

    describe "which Filing rules stop it" do
      it "is nothing when an active Filing rule fits, since the rule files it" do
        filed("LOBLAWS #1234", groceries)
        create(:budget_filing_rule, budget: budget, envelope: household, text: "loblaws")

        expect(guess(unfiled("LOBLAWS #5678"))).to be_nil
      end

      it "is nothing when an active rule that ignores fits" do
        filed("LOBLAWS #1234", groceries)
        create(:budget_filing_rule, :ignore, budget: budget, text: "loblaws")

        expect(guess(unfiled("LOBLAWS #5678"))).to be_nil
      end

      it "is still worked out when the rule that fits is for an archived envelope, which is inactive" do
        filed("LOBLAWS #1234", groceries)
        closed = create(:budget_envelope, budget: budget, name: "Closed")
        create(:budget_filing_rule, budget: budget, envelope: closed, text: "loblaws")
        closed.archive!

        expect(guess(unfiled("LOBLAWS #5678"))).to have_attributes(envelope_id: groceries.id)
      end

      it "is still worked out when a rule that doesn't fit exists, such as for the other way, another Account or another amount" do
        filed("LOBLAWS #1234", groceries)
        create(:budget_filing_rule, :refund, budget: budget, text: "loblaws")
        create(:budget_filing_rule, budget: budget, envelope: household, text: "loblaws", account: create(:budget_account, budget: budget))
        create(:budget_filing_rule, budget: budget, envelope: household, text: "loblaws", amount: -99)

        expect(guess(unfiled("LOBLAWS #5678", amount: -20))).to have_attributes(envelope_id: groceries.id)
      end
    end

    describe "its cost" do
      it "makes the same number of queries with 10 filed bank transactions as with 1,000" do
        row = unfiled("MERCHANT 3 1000")
        file_in_bulk(0...10, groceries)
        expect(guess(row)).to have_attributes(envelope_id: groceries.id)
        few = count_queries { guess(row) }

        file_in_bulk(10...1000, household)
        expect(guess(row)).to have_attributes(envelope_id: household.id)
        many = count_queries { guess(row) }

        expect(Budget::BankTransaction.filed_record_counts(budget.bank_transactions)[:spends]).to eq(1000)
        expect(many).to eq(few)
      end
    end
  end

  describe "#guesses" do
    it "gives each bank transaction its Guess, by id, and leaves out those with none" do
      filed("LOBLAWS #1234", groceries)
      filed("COSTCO #12", household)
      loblaws = unfiled("LOBLAWS #5678")
      costco = unfiled("COSTCO #99")
      unknown = unfiled("SHELL OIL #55")

      guesses = described_class.new(budget).guesses([ loblaws, costco, unknown ])

      expect(guesses.keys).to contain_exactly(loblaws.id, costco.id)
      expect(guesses[loblaws.id]).to have_attributes(envelope_id: groceries.id)
      expect(guesses[costco.id]).to have_attributes(envelope_id: household.id)
    end

    it "is nothing for nothing" do
      expect(described_class.new(budget).guesses([])).to eq({})
    end

    it "leaves out the ones an active Filing rule fits, and keeps the rest" do
      filed("LOBLAWS #1234", groceries)
      filed("COSTCO #12", household)
      create(:budget_filing_rule, budget: budget, envelope: household, text: "costco")

      guesses = described_class.new(budget).guesses([ unfiled("LOBLAWS #5678"), unfiled("COSTCO #99") ])

      expect(guesses.values.map(&:envelope_id)).to eq([ groceries.id ])
    end

    it "makes the same number of queries for 5 bank transactions as for 100" do
      filed("LOBLAWS #1234", groceries)
      create(:budget_filing_rule, budget: budget, envelope: household, text: "costco")
      few_rows = Array.new(5) { |n| unfiled("LOBLAWS ##{n}") }
      many_rows = Array.new(100) { |n| unfiled(n.even? ? "LOBLAWS ##{n}" : "COSTCO ##{n}") }

      few = count_queries { described_class.new(budget).guesses(few_rows) }
      many = count_queries { described_class.new(budget).guesses(many_rows) }

      expect(many).to eq(few)
    end
  end

  describe Budget::Guess do
    it "is what the filing form starts as: the kind, and the envelope if it has one" do
      expect(described_class.new(kind: "spend", envelope_id: 7, envelope_name: "Groceries", like: "LOBLAWS #1234").draft_attributes).to eq(kind: "spend", envelope_id: 7)
      expect(described_class.new(kind: "deposit", envelope_id: nil, envelope_name: nil, like: "ACME PAYROLL").draft_attributes).to eq(kind: "deposit", envelope_id: nil)
    end
  end
end
