require "rails_helper"

RSpec.describe Budget::BankTransaction, type: :model do
  subject { build(:budget_bank_transaction) }

  it { is_expected.to belong_to(:account).class_name("Budget::Account") }
  it { is_expected.to belong_to(:import).class_name("Budget::Import") }

  it "uses the budget_bank_transactions table, and is named without the Budget prefix in routes and params" do
    expect(Budget::BankTransaction.table_name).to eq("budget_bank_transactions")
    expect(Budget::BankTransaction.model_name).to have_attributes(route_key: "bank_transactions", param_key: "bank_transaction")
  end

  it "has no budget of its own: it's in the budget of its Account" do
    expect(Budget::BankTransaction.column_names).not_to include("budget_id")
    budget = create(:budget)
    mine = create(:budget_bank_transaction, account: create(:budget_account, budget: budget))
    create(:budget_bank_transaction)

    expect(budget.bank_transactions).to contain_exactly(mine)
  end

  describe "description" do
    it { is_expected.to validate_presence_of(:description) }

    it "is as the bank gave it, trimmed, and no more" do
      expect(Budget::BankTransaction.new(description: "  LOBLAWS   #1234 \n").description).to eq("LOBLAWS   #1234")
    end

    it "can't be only whitespace" do
      transaction = build(:budget_bank_transaction, description: " \n ")

      expect(transaction).not_to be_valid
      expect(transaction.errors.full_messages).to eq([ "Description can't be blank" ])
    end
  end

  describe "date" do
    it "is required" do
      transaction = build(:budget_bank_transaction, date: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors.full_messages).to eq([ "Date can't be blank" ])
    end
  end

  describe "amount" do
    it "is signed: money in is positive, and money out is negative" do
      expect(build(:budget_bank_transaction, amount: "12.50")).to be_valid
      expect(build(:budget_bank_transaction, amount: "-12.50")).to be_valid
    end

    it "is never 0" do
      transaction = build(:budget_bank_transaction, amount: "0")

      expect(transaction).not_to be_valid
      expect(transaction.errors.full_messages).to eq([ "Amount must be other than 0" ])
    end

    it "accepts up to 2 decimal places, and rejects more instead of rounding" do
      expect(build(:budget_bank_transaction, amount: "1234.56")).to be_valid

      transaction = build(:budget_bank_transaction, amount: "10.005")

      expect(transaction).not_to be_valid
      expect(transaction.errors.full_messages).to eq([ "Amount can't have more than 2 decimal places" ])
    end

    it "is under 10**13 in size, either way" do
      expect(build(:budget_bank_transaction, amount: "9999999999999.99")).to be_valid
      expect(build(:budget_bank_transaction, amount: "-9999999999999.99")).to be_valid
      expect(build(:budget_bank_transaction, amount: "10000000000000")).not_to be_valid
      expect(build(:budget_bank_transaction, amount: "-10000000000000")).not_to be_valid
    end
  end

  describe "the content key and occurrence, which say which row it is in its Account (ADR 0010)" do
    let(:account) { create(:budget_account) }

    def key_of(**attributes)
      create(:budget_bank_transaction, account: account, **attributes).content_key
    end

    it "is a digest, made when it's created" do
      expect(create(:budget_bank_transaction).content_key).to match(/\A[0-9a-f]{64}\z/)
    end

    it "is the same for the same Account, date, signed amount and description, and different for any of them being different" do
      original = Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 9, 15), amount: BigDecimal("-4.25"), description: "Coffee shop")

      expect(Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 9, 15), amount: BigDecimal("-4.25"), description: "Coffee shop")).to eq(original)
      expect(Budget::BankTransaction.content_key(account_id: account.id + 1, date: Date.new(2026, 9, 15), amount: BigDecimal("-4.25"), description: "Coffee shop")).not_to eq(original)
      expect(Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 9, 16), amount: BigDecimal("-4.25"), description: "Coffee shop")).not_to eq(original)
      expect(Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 9, 15), amount: BigDecimal("4.25"), description: "Coffee shop")).not_to eq(original)
      expect(Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 9, 15), amount: BigDecimal("-4.26"), description: "Coffee shop")).not_to eq(original)
      expect(Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 9, 15), amount: BigDecimal("-4.25"), description: "Tea shop")).not_to eq(original)
    end

    it "reads an amount the same however many zeros it was written with" do
      expect(Budget::BankTransaction.content_key(account_id: 1, date: Date.new(2026, 9, 15), amount: BigDecimal("-4.5"), description: "Coffee"))
        .to eq(Budget::BankTransaction.content_key(account_id: 1, date: Date.new(2026, 9, 15), amount: BigDecimal("-4.50"), description: "Coffee"))
    end

    it "reads the description trimmed, with its whitespace collapsed and its case folded" do
      original = Budget::BankTransaction.content_key(account_id: 1, date: Date.new(2026, 9, 15), amount: 5, description: "Loblaws #1234")

      [ "  LOBLAWS #1234", "loblaws   #1234 ", "Loblaws\t#1234" ].each do |description|
        expect(Budget::BankTransaction.content_key(account_id: 1, date: Date.new(2026, 9, 15), amount: 5, description: description)).to eq(original)
      end
    end

    it "numbers the same row's occurrences from 1, so two identical coffees on one day are both kept" do
      first = create(:budget_bank_transaction, account: account, description: "Coffee shop", amount: -4.25)
      second = create(:budget_bank_transaction, account: account, description: "Coffee shop", amount: -4.25)
      other = create(:budget_bank_transaction, account: account, description: "Tea shop", amount: -4.25)

      expect(first.content_key).to eq(second.content_key)
      expect([ first.occurrence, second.occurrence, other.occurrence ]).to eq([ 1, 2, 1 ])
    end

    it "keeps what it was made with, even when the description changes, since it records how the row first looked" do
      transaction = create(:budget_bank_transaction, description: "Coffee shop")
      key, occurrence = transaction.content_key, transaction.occurrence

      transaction.update!(description: "COFFEE SHOP INC")

      expect(transaction.reload).to have_attributes(content_key: key, occurrence: occurrence)
    end
  end

  describe "the normalized description, which a Filing rule and a Guess read" do
    it "is the description trimmed, with its whitespace collapsed and its case folded, and kept by the database" do
      transaction = create(:budget_bank_transaction, description: "  LOBLAWS   #1234 ")

      expect(transaction.reload.normalized_description).to eq("loblaws #1234")
    end

    it "follows the description when it changes, unlike the content key" do
      transaction = create(:budget_bank_transaction, description: "Coffee shop")

      transaction.update!(description: "COFFEE  SHOP INC")

      expect(transaction.reload.normalized_description).to eq("coffee shop inc")
    end

    it "can't be set, since only the description decides it" do
      transaction = create(:budget_bank_transaction, description: "Coffee shop")

      transaction.update!(normalized_description: "something else", amount: -11)

      expect(transaction.reload.normalized_description).to eq("coffee shop")
    end
  end

  describe ".newest_first" do
    it "orders by date, and by the order they were made in within a day" do
      account = create(:budget_account)
      older = create(:budget_bank_transaction, account: account, date: Date.new(2026, 9, 1))
      first_that_day = create(:budget_bank_transaction, account: account, date: Date.new(2026, 9, 10))
      second_that_day = create(:budget_bank_transaction, account: account, date: Date.new(2026, 9, 10))

      expect(account.bank_transactions.newest_first).to eq([ second_that_day, first_that_day, older ])
    end
  end

  describe "its state, which is derived and never stored" do
    it "is unfiled when it has no records and isn't ignored" do
      transaction = create(:budget_bank_transaction)

      expect(transaction).to be_unfiled
      expect(transaction).not_to be_filed
      expect(transaction).not_to be_ignored
      expect(transaction.state).to eq(:unfiled)
    end

    it "is ignored when it was ignored" do
      transaction = create(:budget_bank_transaction, :ignored)

      expect(transaction).to be_ignored
      expect(transaction).not_to be_filed
      expect(transaction).not_to be_unfiled
      expect(transaction.state).to eq(:ignored)
    end

    it "is filed when it has at least one link, of any kind" do
      [ [ :budget_deposit_link, 10 ], [ :budget_spend_link, -10 ], [ :budget_refund_link, 10 ] ].each do |factory, amount|
        transaction = create(:budget_bank_transaction, amount: amount)
        create(factory, bank_transaction: transaction)

        expect(transaction.reload).to be_filed
        expect(transaction).not_to be_unfiled
        expect(transaction.state).to eq(:filed)
      end
    end

    it "has no column for it, apart from when it was ignored" do
      expect(Budget::BankTransaction.column_names).to include("ignored_at")
      expect(Budget::BankTransaction.column_names).not_to include("state", "status", "filed_at")
    end

    it "can't be both ignored and filed: ignoring one that's filed is refused" do
      transaction = create(:budget_bank_transaction, :filed)

      expect(transaction.update(ignored_at: Time.current)).to be(false)

      expect(transaction.errors.full_messages).to eq([ "Bank transaction is filed, so it can't be ignored" ])
      expect(transaction.reload.ignored_at).to be_nil
    end

    it "can be ignored when it isn't filed, and unignored" do
      transaction = create(:budget_bank_transaction)

      expect(transaction.update(ignored_at: Time.current)).to be(true)
      expect(transaction.update(ignored_at: nil)).to be(true)
    end

    it "is found by the .unfiled scope when it's neither ignored nor filed, whichever kind of link the others have" do
      unfiled = create(:budget_bank_transaction)
      create(:budget_bank_transaction, :ignored)
      create(:budget_bank_transaction, :filed)
      create(:budget_bank_transaction, :filed, amount: 25)
      refunded = create(:budget_bank_transaction, amount: 5)
      create(:budget_refund_link, bank_transaction: refunded)
      split = create(:budget_bank_transaction, amount: -10)
      2.times { create(:budget_spend_link, bank_transaction: split) }

      expect(Budget::BankTransaction.unfiled).to contain_exactly(unfiled)
    end

    describe "the state scopes" do
      let!(:unfiled) { create(:budget_bank_transaction) }
      let!(:ignored) { create(:budget_bank_transaction, :ignored) }
      let!(:deposited) { create(:budget_bank_transaction, :filed, amount: 25) }
      let!(:spent) { create(:budget_bank_transaction, :filed) }
      let!(:refunded) { create(:budget_bank_transaction, amount: 5).tap { |transaction| create(:budget_refund_link, bank_transaction: transaction) } }
      let!(:split) do
        create(:budget_bank_transaction, amount: -10).tap do |transaction|
          2.times { create(:budget_spend_link, bank_transaction: transaction) }
        end
      end

      it "has .filed for what's filed as at least one record, of any kind, and each only once, however many links it has" do
        expect(Budget::BankTransaction.filed).to contain_exactly(deposited, spent, refunded, split)
        expect(Budget::BankTransaction.filed.count).to eq(4)
      end

      it "has .ignored for what's ignored" do
        expect(Budget::BankTransaction.ignored).to contain_exactly(ignored)
      end

      it "puts every bank transaction in exactly one of the three" do
        all = Budget::BankTransaction.all.to_a

        expect(Budget::BankTransaction.unfiled.to_a + Budget::BankTransaction.filed.to_a + Budget::BankTransaction.ignored.to_a).to match_array(all)
      end

      it "keeps .filed and .ignored apart even for one that somehow has both, since the model refuses to make one" do
        # A bank transaction is never both ignored and filed (the model refuses it), so one that is has been made some other way, and is
        # ignored, since that's the state ignored? gives it.
        spent.update_columns(ignored_at: Time.current)

        expect(Budget::BankTransaction.ignored).to include(spent)
        expect(Budget::BankTransaction.filed).not_to include(spent)
        expect(spent.reload.state).to eq(:ignored)
      end

      it "combine with the others and with a budget's own bank transactions, which are found through its Accounts" do
        budget = create(:budget)
        account = create(:budget_account, budget: budget)
        mine = create(:budget_bank_transaction, :filed, account: account)
        create(:budget_bank_transaction, account: account)

        expect(budget.bank_transactions.filed).to contain_exactly(mine)
        expect(budget.bank_transactions.filed.newest_first.preload(:account).to_a).to eq([ mine ])
        expect(budget.bank_transactions.ignored).to be_empty
      end
    end
  end

  describe "#ignore" do
    it "sets when it was ignored" do
      transaction = create(:budget_bank_transaction)

      travel_to(Time.zone.local(2026, 9, 20, 9)) { transaction.ignore }

      expect(transaction.reload.ignored_at).to eq(Time.zone.local(2026, 9, 20, 9))
      expect(transaction).to be_ignored
    end

    it "is refused for one that's filed, saying so, and changes nothing" do
      transaction = create(:budget_bank_transaction, :filed)

      expect { transaction.ignore }.to raise_error(Budget::BankTransaction::Refused, "This bank transaction is filed. Un-file it before ignoring it.")

      expect(transaction.reload.ignored_at).to be_nil
    end

    it "is refused for one that's already ignored, and leaves when it was" do
      transaction = create(:budget_bank_transaction, :ignored)
      ignored_at = transaction.ignored_at

      expect { transaction.ignore }.to raise_error(Budget::BankTransaction::Refused, "This bank transaction is already ignored.")

      expect(transaction.reload.ignored_at).to eq(ignored_at)
    end

    it "judges it once the bank transaction is locked, so a record filed since it was looked at stops it" do
      transaction = create(:budget_bank_transaction)
      stale = Budget::BankTransaction.find(transaction.id)
      create(:budget_spend_link, bank_transaction: transaction)

      expect { stale.ignore }.to raise_error(Budget::BankTransaction::Refused, /filed/)
    end
  end

  describe "#unignore" do
    it "clears when it was ignored, which makes it unfiled again" do
      transaction = create(:budget_bank_transaction, :ignored)

      transaction.unignore

      expect(transaction.reload).to be_unfiled
      expect(transaction.ignored_at).to be_nil
    end

    it "is refused for one that isn't ignored" do
      expect { create(:budget_bank_transaction).unignore }.to raise_error(Budget::BankTransaction::Refused, "This bank transaction isn't ignored.")
    end
  end

  describe "#unfile" do
    it "deletes the records it was filed as and their links, which makes it unfiled again, and deletes nothing else" do
      transaction = create(:budget_bank_transaction, :filed)
      other = create(:budget_bank_transaction, :filed)
      spend = transaction.spend_links.sole.spend

      expect { transaction.unfile }.to change(Budget::Spend, :count).by(-1).and change(Budget::SpendLink, :count).by(-1)

      expect(Budget::Spend.exists?(spend.id)).to be(false)
      expect(transaction.reload).to be_unfiled
      expect(Budget::BankTransaction.exists?(transaction.id)).to be(true)
      expect(other.reload).to be_filed
      expect(Budget::Spend.count).to eq(1)
    end

    it "deletes every record when there are several, of any kind" do
      transaction = create(:budget_bank_transaction, amount: 10)
      create(:budget_deposit_link, bank_transaction: transaction)
      create(:budget_refund_link, bank_transaction: transaction)

      expect { transaction.unfile }
        .to change(Budget::Deposit, :count).by(-1).and change(Budget::Refund, :count).by(-1)
        .and change(Budget::DepositLink, :count).by(-1).and change(Budget::RefundLink, :count).by(-1)

      expect(transaction.reload).to be_unfiled
    end

    it "is refused for one that isn't filed, saying so" do
      expect { create(:budget_bank_transaction).unfile }.to raise_error(Budget::BankTransaction::Refused, "This bank transaction isn't filed.")
      expect { create(:budget_bank_transaction, :ignored).unfile }.to raise_error(Budget::BankTransaction::Refused, "This bank transaction isn't filed.")
    end

    it "is all or nothing" do
      transaction = create(:budget_bank_transaction, :filed)
      allow(Budget::Spend).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "the database went away")

      expect { transaction.unfile }.to raise_error(ActiveRecord::StatementInvalid)

      expect(transaction.reload).to be_filed
    end
  end

  # Which Filing rule filed or ignored it is only ever read while it's filed or ignored: a person's filing writes none, un-filing and
  # un-ignoring clear it, and nothing about it makes a rule act again.
  describe "the Filing rule that filed or ignored it" do
    let(:transaction) { create(:budget_bank_transaction) }
    let(:rule) { create(:budget_filing_rule, :ignore, budget: transaction.account.budget) }

    it "is the rule while it's filed, or ignored, and nothing otherwise" do
      expect(transaction.filed_by_rule).to be_nil

      transaction.update_columns(filing_rule_id: rule.id)
      expect(transaction.reload.filed_by_rule).to be_nil

      create(:budget_spend_link, bank_transaction: transaction)
      expect(transaction.reload.filed_by_rule).to eq(rule)

      transaction.spend_links.sole.spend.destroy!
      expect(transaction.reload.filed_by_rule).to be_nil

      transaction.update_columns(ignored_at: Time.current)
      expect(transaction.reload.filed_by_rule).to eq(rule)
    end

    it "goes stale but inert when its last record is deleted by hand" do
      filed = create(:budget_bank_transaction, :filed)
      filed.update_columns(filing_rule_id: rule.id)

      filed.spend_links.sole.spend.destroy!

      expect(filed.reload).to be_unfiled
      expect(filed.filing_rule_id).to eq(rule.id)
      expect(filed.filed_by_rule).to be_nil
    end

    it "is cleared when it's un-filed, which doesn't file it again" do
      filed = create(:budget_bank_transaction, :filed)
      filed.update_columns(filing_rule_id: rule.id)

      filed.unfile

      expect(filed.reload.filing_rule_id).to be_nil
      expect(filed).to be_unfiled
      expect(Budget::Spend.count).to eq(0)
    end

    it "is cleared when it's un-ignored, which doesn't ignore it again" do
      ignored = create(:budget_bank_transaction, :ignored)
      ignored.update_columns(filing_rule_id: rule.id)

      ignored.unignore

      expect(ignored.reload.filing_rule_id).to be_nil
      expect(ignored).to be_unfiled
    end

    it "is none when a person ignores it, over a value that went stale" do
      transaction.update_columns(filing_rule_id: rule.id)

      transaction.ignore

      expect(transaction.reload.filing_rule_id).to be_nil
      expect(transaction).to be_ignored
    end

    it "is left with its rule's deletion as none, and it's still filed" do
      filed = create(:budget_bank_transaction, :filed)
      filed.update_columns(filing_rule_id: rule.id)

      rule.destroy!

      expect(filed.reload.filing_rule_id).to be_nil
      expect(filed).to be_filed
    end
  end

  describe "what it was filed as" do
    let(:transaction) { create(:budget_bank_transaction, amount: -100) }

    it "is its records, whichever kind, and what they add up to" do
      create(:budget_spend_link, bank_transaction: transaction, spend: create(:budget_spend, envelope: create(:budget_envelope, budget: transaction.account.budget, name: "Groceries"), amount: 60))
      create(:budget_spend_link, bank_transaction: transaction, spend: create(:budget_spend, envelope: create(:budget_envelope, budget: transaction.account.budget, name: "Household"), amount: 40))
      transaction.reload

      expect(transaction.filed_records.map { |record| [ record.class, record.amount ] }).to contain_exactly([ Budget::Spend, 60 ], [ Budget::Spend, 40 ])
      expect(transaction.filed_total).to eq(100)
      expect(transaction).to be_adds_up
    end

    it "adds up when the records are of the amount in whichever direction, and doesn't when they aren't" do
      link = create(:budget_spend_link, bank_transaction: transaction, spend: create(:budget_spend, envelope: create(:budget_envelope, budget: transaction.account.budget), amount: 100))
      expect(transaction.reload).to be_adds_up

      link.spend.update!(amount: 90)

      expect(transaction.reload).not_to be_adds_up
      expect(transaction.filed_total).to eq(90)
    end

    it "has nothing to add up when it isn't filed, so it isn't flagged" do
      expect(transaction.filed_total).to eq(0)
      expect(transaction).to be_adds_up
    end
  end

  describe "database constraints" do
    let(:transaction) { create(:budget_bank_transaction, description: "Coffee shop", date: Date.new(2026, 9, 15), amount: -4.25) }

    # Plain SQL, because the model would normalize or reject most of these values before the database saw them. Each runs in
    # a savepoint, because PostgreSQL aborts the transaction at the first violation, which would stop an example from
    # checking a second one.
    def update_transaction(transaction, assignments)
      Budget::BankTransaction.transaction(requires_new: true) { Budget::BankTransaction.where(id: transaction.id).update_all(assignments) }
    end

    it "rejects an amount of 0" do
      expect { update_transaction(transaction, "amount = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_bank_transactions_amount_not_zero/)
    end

    it "rejects a blank description" do
      expect { update_transaction(transaction, "description = '   '") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_bank_transactions_description_not_blank/)
    end

    it "rejects a content key that isn't a digest" do
      expect { update_transaction(transaction, "content_key = 'abc'") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_bank_transactions_content_key_format/)
    end

    it "rejects an occurrence below 1" do
      expect { update_transaction(transaction, "occurrence = 0") }
        .to raise_error(ActiveRecord::CheckViolation, /budget_bank_transactions_occurrence_positive/)
    end

    it "rejects a second row with the same Account, content key and occurrence" do
      other = create(:budget_bank_transaction, account: transaction.account, description: "Tea shop")

      expect { update_transaction(other, ActiveRecord::Base.sanitize_sql_array([ "content_key = ?", transaction.content_key ])) }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_budget_bank_transactions_on_content_key_and_occurrence/)
    end

    it "allows the same content key and occurrence in another Account" do
      other = create(:budget_bank_transaction, description: "Tea shop")

      expect { update_transaction(other, ActiveRecord::Base.sanitize_sql_array([ "content_key = ?", transaction.content_key ])) }.not_to raise_error
    end

    %w[ account_id import_id date description amount content_key occurrence ].each do |column|
      it "requires a #{column}" do
        expect { update_transaction(transaction, "#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "keeps an Account with bank transactions from being deleted without them" do
      expect { Budget::Account.where(id: transaction.account_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end

    it "keeps an Import with bank transactions from being deleted without them" do
      expect { Budget::Import.where(id: transaction.import_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end

  describe "#next_unfiled" do
    let(:budget) { create(:budget) }
    let(:account) { create(:budget_account, budget: budget) }
    let(:scope) { budget.bank_transactions }

    def row(date, **attributes)
      create(:budget_bank_transaction, account: account, date: Date.new(2026, 9, date), **attributes)
    end

    it "is the first unfiled bank transaction older than this one, in the order the list has: newest first, by date and then id" do
      newest = row(20)
      current = row(15)
      older = row(10)
      oldest = row(5)

      expect(newest.next_unfiled(scope: scope)).to eq(current)
      expect(current.next_unfiled(scope: scope)).to eq(older)
      expect(older.next_unfiled(scope: scope)).to eq(oldest)
    end

    it "goes by id for bank transactions of the same date, the later id being the newer" do
      first = row(15)
      second = row(15)
      third = row(15)

      expect(third.next_unfiled(scope: scope)).to eq(second)
      expect(second.next_unfiled(scope: scope)).to eq(first)
    end

    it "wraps to the newest unfiled one left when there's none older, so working from the middle of the list finishes it" do
      newest = row(20)
      current = row(15)
      oldest = row(5)

      expect(oldest.next_unfiled(scope: scope)).to eq(newest)
      expect(current.next_unfiled(scope: scope)).to eq(oldest)
    end

    it "wraps to the newest one when the only one that's left is newer" do
      newer = row(20)
      current = row(15)

      expect(current.next_unfiled(scope: scope)).to eq(newer)
    end

    it "is nothing when no other bank transaction is unfiled, and never the one it's asked about" do
      current = row(15)
      create(:budget_bank_transaction, :filed, account: account, date: Date.new(2026, 9, 10))

      expect(current.next_unfiled(scope: scope)).to be_nil
    end

    it "never offers one that's filed or ignored, whichever side of this one it's on" do
      row(20, amount: -5).tap { |newer| create(:budget_spend_link, bank_transaction: newer) }
      current = row(15)
      create(:budget_bank_transaction, :ignored, account: account, date: Date.new(2026, 9, 10))
      older_filed = create(:budget_bank_transaction, :filed, account: account, date: Date.new(2026, 9, 5))
      unfiled = row(1)

      expect(older_filed).to be_filed
      expect(current.next_unfiled(scope: scope)).to eq(unfiled)
    end

    it "is judged when it's asked, so one that has just been filed is never offered" do
      current = row(15)
      just_filed = row(10)
      older = row(5)
      create(:budget_spend_link, bank_transaction: just_filed)

      expect(current.next_unfiled(scope: scope)).to eq(older)
    end

    it "stays in the scope it's given: one Account's, and the budget's own, never another budget's" do
      other_account = create(:budget_account, budget: budget)
      current = row(15)
      in_other_account = create(:budget_bank_transaction, account: other_account, date: Date.new(2026, 9, 10))
      someone_elses = create(:budget_bank_transaction, date: Date.new(2026, 9, 12))

      expect(current.next_unfiled(scope: scope)).to eq(in_other_account)
      expect(current.next_unfiled(scope: account.bank_transactions)).to be_nil
      expect(current.next_unfiled(scope: scope)).not_to eq(someone_elses)
    end

    it "is found with one query, wrap included" do
      current = row(15)
      5.times { |n| row(n + 1) }
      older = row(1)

      queries = count_queries { current.next_unfiled(scope: scope) }
      old_queries = count_queries { older.next_unfiled(scope: scope) }

      expect(queries).to eq(1)
      expect(old_queries).to eq(1)
    end
  end
end
