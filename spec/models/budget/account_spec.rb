require "rails_helper"

RSpec.describe Budget::Account, type: :model do
  subject { build(:budget_account) }

  it { is_expected.to belong_to(:budget) }
  it { is_expected.to have_many(:bank_transactions).class_name("Budget::BankTransaction").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:imports).class_name("Budget::Import").dependent(:destroy) }
  it { is_expected.to belong_to(:default_csv_format).class_name("Budget::CsvFormat").optional }
  it { is_expected.to belong_to(:bank_connection).class_name("Budget::BankConnection").optional }

  it "uses the budget_accounts table, and is named without the Budget prefix in routes and params" do
    expect(Budget::Account.table_name).to eq("budget_accounts")
    expect(Budget::Account.model_name).to have_attributes(route_key: "accounts", param_key: "account")
  end

  it "has no balance, currency, kind or last four digits, since Budgie doesn't track what's in it" do
    expect(Budget::Account.column_names).to contain_exactly("id", "budget_id", "name", "default_csv_format_id", "files_with_rules", "bank_connection_id", "external_account_id", "created_at", "updated_at")
  end

  describe "name" do
    it { is_expected.to validate_presence_of(:name) }

    it "squishes surrounding and repeated whitespace" do
      expect(Budget::Account.new(name: "  Joint \n chequing  ").name).to eq("Joint chequing")
    end

    it "can't be only whitespace" do
      account = build(:budget_account, name: " \n ")

      expect(account).not_to be_valid
      expect(account.errors.full_messages).to eq([ "Name can't be blank" ])
    end

    it "is unique in a budget, whatever its case" do
      budget = create(:budget)
      create(:budget_account, budget: budget, name: "Chequing")

      account = build(:budget_account, budget: budget, name: "CHEQUING")

      expect(account).not_to be_valid
      expect(account.errors.full_messages).to eq([ "Name has already been taken" ])
    end

    it "may be the same as another budget's" do
      create(:budget_account, name: "Chequing")

      expect(build(:budget_account, name: "Chequing")).to be_valid
    end
  end

  describe "its default CSV format" do
    let(:budget) { create(:budget) }
    let(:csv_format) { create(:budget_csv_format, budget: budget) }

    it "is optional: nothing requires an Account to have one" do
      account = build(:budget_account, budget: budget)

      expect(account).to be_valid
      expect(account.default_csv_format).to be_nil
      expect(account.save).to be(true)
    end

    it "can be one of the Account's own budget's CSV formats" do
      account = create(:budget_account, budget: budget, default_csv_format: csv_format)

      expect(account.reload.default_csv_format).to eq(csv_format)
    end

    it "is refused when it's another budget's, with the error on default_csv_format, worded as a Filing rule's are" do
      account = build(:budget_account, budget: budget, default_csv_format: create(:budget_csv_format))

      expect(account).not_to be_valid
      expect(account.errors[:default_csv_format]).to eq([ "isn't one of this budget's" ])
      expect(account.errors.full_messages).to eq([ "Default CSV format isn't one of this budget's" ])
    end

    it "is refused when the id names no CSV format at all, and not left for the database's foreign key" do
      account = build(:budget_account, budget: budget, default_csv_format_id: 0)

      expect(account).not_to be_valid
      expect(account.errors[:default_csv_format]).to eq([ "isn't one of this budget's" ])
    end

    it "is checked when it's changed, and may be cleared, since it's optional" do
      account = create(:budget_account, budget: budget, default_csv_format: csv_format)

      expect(account.update(default_csv_format: create(:budget_csv_format))).to be(false)
      expect(account.update(default_csv_format: nil)).to be(true)
      expect(account.reload.default_csv_format).to be_nil
    end

    it "keeps its CSV format from being deleted out from under it, in the database too" do
      create(:budget_account, budget: budget, default_csv_format: csv_format)

      expect { Budget::CsvFormat.where(id: csv_format.id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /RestrictViolation|violates foreign key/)
    end
  end

  describe "being synced from a connection" do
    let(:budget) { create(:budget) }
    let(:connection) { create(:budget_bank_connection, budget: budget, login_id: "4321") }

    it "is something an Account may or may not be: one known only from CSV files has neither a connection nor an external id" do
      account = create(:budget_account, budget: budget)

      expect(account).not_to be_synced
      expect(account.reload).to have_attributes(bank_connection: nil, external_account_id: nil)
    end

    it "is synced once it has a connection, whatever state the connection is in" do
      account = create(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321")

      expect(account).to be_synced
      connection.disconnect!
      expect(account.reload).to be_synced
    end

    it "needs its external id, which for Splitwise is the Splitwise user's id, and has no use for one without a connection" do
      without_id = build(:budget_account, budget: budget, bank_connection: connection)
      without_connection = build(:budget_account, budget: budget, external_account_id: "4321")

      expect(without_id).not_to be_valid
      expect(without_id.errors[:external_account_id]).to eq([ "can't be blank" ])
      expect(without_connection).not_to be_valid
      expect(without_connection.errors[:external_account_id]).to eq([ "needs a connection" ])
    end

    it "is refused when the connection is another budget's, with the error on the connection, worded as a default CSV format's is" do
      account = build(:budget_account, budget: budget, bank_connection: create(:budget_bank_connection), external_account_id: "1")

      expect(account).not_to be_valid
      expect(account.errors[:bank_connection]).to eq([ "isn't one of this budget's" ])
    end

    it "has one Account for each external id of a connection" do
      create(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321")

      same = build(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321")

      expect(same).not_to be_valid
      expect(same.errors[:external_account_id]).to eq([ "is already synced" ])
    end

    it "has the Splitwise user's id as its external id when it's synced from Splitwise, which is why a Splitwise connection has one Account" do
      other_id = build(:budget_account, budget: budget, bank_connection: connection, external_account_id: "8765")

      expect(other_id).not_to be_valid
      expect(other_id.errors[:external_account_id]).to eq([ "must be the Splitwise user's id" ])
      expect(build(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321")).to be_valid
    end

    it "can't have a second Account made on a Splitwise connection, since the only id it can have is the one that's taken" do
      create(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321")

      second = build(:budget_account, budget: budget, name: "Another", bank_connection: connection, external_account_id: "8765")

      expect(second).not_to be_valid
    end

    it "has no default CSV format, since it has no files, which is refused from any way in and not only by its form" do
      account = create(:budget_account, :synced, budget: budget)
      account.default_csv_format = create(:budget_csv_format, budget: budget)

      expect(account).not_to be_valid
      expect(account.errors[:default_csv_format]).to eq([ "isn't used by an Account that's synced" ])
    end

    it "is found among the Accounts a CSV file can be imported into only when it isn't synced" do
      csv = create(:budget_account, budget: budget)
      create(:budget_account, :synced, budget: budget)

      expect(Budget::Account.importable).to eq([ csv ])
    end

    it "has a connection and an external id together or not at all, which the database checks too" do
      account = create(:budget_account, budget: budget)

      [ { external_account_id: "4321" }, { bank_connection_id: connection.id } ].each do |assignments|
        expect { Budget::Account.transaction(requires_new: true) { Budget::Account.where(id: account.id).update_all(assignments) } }
          .to raise_error(ActiveRecord::CheckViolation, /budget_accounts_connection_with_external_id/)
      end
    end

    it "has a connection that the database keeps from being deleted from under it" do
      create(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321")

      expect { Budget::BankConnection.where(id: connection.id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end

    it "takes its connection with it when it's deleted, since a Splitwise connection has no other Account" do
      account = create(:budget_account, :synced, budget: budget)

      expect { account.destroy! }.to change(Budget::Account, :count).by(-1).and change(Budget::BankConnection, :count).by(-1)
    end

    it "leaves a connection that another Account is synced from, as a provider with several accounts to a connection would" do
      account = create(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321")
      # Splitwise's connection has only the one, so this is made past the validation that says so, which is what a provider with several would be.
      other = build(:budget_account, budget: budget, name: "Another", bank_connection: connection, external_account_id: "8765").tap { |another| another.save!(validate: false) }

      expect { account.destroy! }.not_to change(Budget::BankConnection, :count)
      expect { other.destroy! }.to change(Budget::BankConnection, :count).by(-1)
    end

    it "keeps its connection when it's refused for having bank transactions" do
      account = create(:budget_account, :synced, budget: budget)
      create(:budget_bank_transaction, account: account)

      expect(account.destroy).to be(false)

      expect(Budget::BankConnection.exists?(account.bank_connection_id)).to be(true)
    end

    it "takes a disconnected connection with it, as it would any other" do
      account = create(:budget_account, :synced, budget: budget)
      account.bank_connection.disconnect!

      expect { account.destroy! }.to change(Budget::BankConnection, :count).by(-1)
    end
  end

  describe "files_with_rules" do
    it "is on for a new Account, so every Account keeps working as it did before the setting" do
      expect(Budget::Account.new.files_with_rules).to be(true)
      expect(create(:budget_account).reload.files_with_rules).to be(true)
    end

    it "can be turned off, which keeps Filing rules from acting on the Account's bank transactions" do
      account = create(:budget_account, files_with_rules: false)

      expect(account.reload.files_with_rules).to be(false)
    end

    it "has scopes for the Accounts that have Filing rules on and the ones that have them off" do
      on = create(:budget_account)
      off = create(:budget_account, budget: on.budget, files_with_rules: false)

      expect(Budget::Account.with_filing_rules).to eq([ on ])
      expect(Budget::Account.without_filing_rules).to eq([ off ])
    end
  end

  describe "#latest_import" do
    let(:account) { create(:budget_account) }

    it "is the one that ran last, and none when nothing has been imported" do
      expect(account.latest_import).to be_nil

      create(:budget_import, account: account, created_at: 3.days.ago)
      newest = create(:budget_import, account: account, created_at: 1.hour.ago)
      create(:budget_import, account: account, created_at: 2.days.ago)
      create(:budget_import, created_at: 1.minute.ago)

      expect(account.latest_import).to eq(newest)
    end

    it "is the one made last when two ran at the same moment" do
      moment = Time.zone.local(2026, 9, 15, 10)
      create(:budget_import, account: account, created_at: moment)
      later = create(:budget_import, account: account, created_at: moment)

      expect(account.latest_import).to eq(later)
    end
  end

  describe "database constraints" do
    let(:account) { create(:budget_account) }

    def update_account(account, assignments)
      Budget::Account.transaction(requires_new: true) { Budget::Account.where(id: account.id).update_all(assignments) }
    end

    it "rejects a blank name" do
      expect { update_account(account, "name = '   '") }.to raise_error(ActiveRecord::CheckViolation, /budget_accounts_name_not_blank/)
    end

    it "rejects the same name in another case in a budget" do
      create(:budget_account, budget: account.budget, name: "Other")

      expect { update_account(account, "name = 'OTHER'") }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_budget_accounts_on_budget_id_and_lower_name/)
    end

    %w[ budget_id name files_with_rules ].each do |column|
      it "requires a #{column}" do
        expect { update_account(account, "#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "keeps a budget with Accounts from being deleted without them" do
      expect { Budget.where(id: account.budget_id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end

  describe "being deleted" do
    it "is refused while it has bank transactions, and keeps them" do
      transaction = create(:budget_bank_transaction)
      account = transaction.account

      expect(account.destroy).to be(false)

      expect(account.errors.full_messages).to eq([ "This account can't be deleted because it has bank transactions." ])
      expect(Budget::Account.exists?(account.id)).to be(true)
      expect(Budget::BankTransaction.exists?(transaction.id)).to be(true)
    end

    it "takes its Imports with it when none of them brought a bank transaction in, such as one of nothing but rows of 0" do
      import = create(:budget_import, zero_rows_skipped: 3)

      expect { import.account.destroy! }.to change(Budget::Account, :count).by(-1).and change(Budget::Import, :count).by(-1)
    end

    it "takes the Filing rules pinned to it with it, when it has no bank transactions, and leaves the ones for any Account" do
      account = create(:budget_account)
      pinned = create(:budget_filing_rule, :ignore, budget: account.budget, account: account, text: "payment thank you")
      anywhere = create(:budget_filing_rule, :ignore, budget: account.budget, text: "interest")

      expect { account.destroy! }.to change(Budget::FilingRule, :count).by(-1)

      expect(Budget::FilingRule.exists?(pinned.id)).to be(false)
      expect(Budget::FilingRule.exists?(anywhere.id)).to be(true)
    end

    it "keeps the Filing rules pinned to it when it's refused for having bank transactions" do
      transaction = create(:budget_bank_transaction)
      rule = create(:budget_filing_rule, :ignore, budget: transaction.account.budget, account: transaction.account)

      expect(transaction.account.destroy).to be(false)

      expect(Budget::FilingRule.exists?(rule.id)).to be(true)
    end
  end
end
