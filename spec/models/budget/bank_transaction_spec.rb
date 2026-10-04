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
end
