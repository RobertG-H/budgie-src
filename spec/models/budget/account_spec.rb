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

  # Plaid's name and mask for a synced account only say which real account it is (the ADR 0001 addendum), and aren't anything tracked about it.
  it "has no balance, currency or kind, since Budgie doesn't track what's in it" do
    expect(Budget::Account.column_names).to contain_exactly("id", "budget_id", "name", "default_csv_format_id", "files_with_rules", "bank_connection_id", "external_account_id",
      "external_name", "external_mask", "read_from", "unshared_at", "created_at", "updated_at")
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
      create(:budget_account, :plaid, budget: budget)

      expect(Budget::Account.importable).to eq([ csv ])
    end

    describe "from a bank through Plaid" do
      let(:plaid) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust") }

      it "is one of the connection's Accounts, with Plaid's id, name and mask for it" do
        account = create(:budget_account, budget: budget, bank_connection: plaid, external_account_id: "acc-1",
          external_name: "TD Every Day Chequing", external_mask: "4821", read_from: Date.new(2026, 10, 1))

        expect(account.reload).to be_synced
        expect(account).to have_attributes(external_name: "TD Every Day Chequing", external_mask: "4821")
      end

      it "says it's synced from the bank, by name, and takes no Import" do
        account = create(:budget_account, :plaid, budget: budget, bank_connection: plaid)

        expect(account.synced_from).to eq("TD Canada Trust")
        expect(account.import_refusal).to eq("is synced from TD Canada Trust, so it takes no Import")
      end

      it "starts money in as a Deposit, as a bank's does, where Splitwise's starts as a Refund" do
        expect(create(:budget_account, :plaid, budget: budget).money_in_kind).to eq("deposit")
        expect(create(:budget_account, :synced, budget: budget).money_in_kind).to eq("refund")
      end

      it "has no Plaid name or mask when it isn't synced, which the database checks too" do
        account = build(:budget_account, budget: budget, external_name: "Chequing", external_mask: "4821")

        expect(account).not_to be_valid
        expect(account.errors[:external_name]).to eq([ "needs a connection" ])
        expect(account.errors[:external_mask]).to eq([ "needs a connection" ])
        expect { account.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /budget_accounts_external_name_when_synced/)
      end

      it "is shared until the person de-selects it in Choose accounts, which only a synced Account can be" do
        account = create(:budget_account, :plaid, budget: budget, bank_connection: plaid)
        expect(account).not_to be_unshared

        account.update!(unshared_at: Time.current)
        expect(account).to be_unshared

        unsynced = build(:budget_account, budget: budget, unshared_at: Time.current)
        expect(unsynced).not_to be_valid
        expect(unsynced.errors[:unshared_at]).to eq([ "needs a connection" ])
        expect { unsynced.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /budget_accounts_unshared_when_synced/)
      end

      it "leaves the connection when another of its Accounts is still synced from it, and takes it with the last" do
        first = create(:budget_account, :plaid, budget: budget, bank_connection: plaid)
        second = create(:budget_account, :plaid, budget: budget, bank_connection: plaid)

        first.destroy!
        expect(Budget::BankConnection.exists?(plaid.id)).to be(true)
        second.destroy!
        expect(Budget::BankConnection.exists?(plaid.id)).to be(false)
      end
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

  # Each synced Account has its own date to read from, so that a connection with several can give each its own (ADR 0018).
  describe "the date to read from" do
    let(:budget) { create(:budget) }
    let(:connection) { create(:budget_bank_connection, budget: budget, login_id: "4321") }

    def synced(**attributes)
      build(:budget_account, budget: budget, bank_connection: connection, external_account_id: "4321", **attributes)
    end

    it "is needed by a synced Account, and has no use on one that isn't" do
      without_date = synced(read_from: nil)
      unsynced = build(:budget_account, budget: budget, read_from: Date.new(2026, 10, 1))

      expect(without_date).not_to be_valid
      expect(without_date.errors[:read_from]).to eq([ "can't be blank" ])
      expect(unsynced).not_to be_valid
      expect(unsynced.errors[:read_from]).to eq([ "needs a connection" ])
      expect(build(:budget_account, budget: budget)).to be_valid
    end

    it "can be today, or the day after, which is today for someone ahead of Eastern time" do
      travel_to Time.utc(2026, 10, 6, 16) do
        expect(synced(read_from: Date.new(2026, 10, 6))).to be_valid
        expect(synced(read_from: Date.new(2026, 10, 7))).to be_valid
      end
    end

    it "can't be more than a day after today, or before 1990" do
      travel_to Time.utc(2026, 10, 6, 16) do
        later = synced(read_from: Date.new(2026, 10, 8))
        earlier = synced(read_from: Date.new(1989, 12, 31))

        expect(later).not_to be_valid
        expect(later.errors[:read_from]).to eq([ "can't be in the future" ])
        expect(earlier).not_to be_valid
        expect(earlier.errors[:read_from]).to eq([ "can't be before 1990" ])
        expect(synced(read_from: Date.new(1990, 1, 1))).to be_valid
      end
    end

    it "is kept when its connection is disconnected" do
      account = create(:budget_account, :synced, budget: budget, read_from: Date.new(2026, 9, 1))

      account.bank_connection.disconnect!

      expect(account.reload.read_from).to eq(Date.new(2026, 9, 1))
    end

    describe "in the database" do
      def update_account(account, assignments)
        Budget::Account.transaction(requires_new: true) { Budget::Account.where(id: account.id).update_all(assignments) }
      end

      it "is there for a synced Account and not for one that isn't" do
        expect { update_account(create(:budget_account, :synced, budget: budget), read_from: nil) }
          .to raise_error(ActiveRecord::CheckViolation, /budget_accounts_read_from_when_synced/)
        expect { update_account(create(:budget_account, budget: budget), read_from: Date.new(2026, 10, 1)) }
          .to raise_error(ActiveRecord::CheckViolation, /budget_accounts_read_from_when_synced/)
      end

      it "can't be before 1990 either, since that limit doesn't depend on the day" do
        expect { update_account(create(:budget_account, :synced, budget: budget), read_from: Date.new(1989, 12, 31)) }
          .to raise_error(ActiveRecord::CheckViolation, /budget_accounts_read_from_not_before_1990/)
      end
    end

    describe ".default_read_from" do
      it "is the date of the budget's earliest bank transaction, so a shared expense the person paid for gets its share back" do
        account = create(:budget_account, budget: budget)
        create(:budget_bank_transaction, account: account, date: Date.new(2026, 7, 3))
        create(:budget_bank_transaction, account: account, date: Date.new(2026, 9, 1))
        create(:budget_bank_transaction, date: Date.new(2020, 1, 1))

        expect(Budget::Account.default_read_from(budget)).to eq(Date.new(2026, 7, 3))
      end

      it "is the 1st of this month when there are none" do
        travel_to Time.zone.local(2026, 10, 19, 12) do
          expect(Budget::Account.default_read_from(budget)).to eq(Date.new(2026, 10, 1))
        end
      end
    end

    describe "#change_read_from" do
      let(:account) { create(:budget_account, :synced, budget: budget, read_from: Date.new(2026, 10, 1)) }

      before { account.bank_connection.update_columns(sync_cursor: "2026-10-05T12:00:00Z") }

      it "writes the Account and clears its connection's sync marker, so the next sync reads from the new date again" do
        expect(account.change_read_from(Date.new(2026, 9, 1))).to be(true)

        expect(account.reload.read_from).to eq(Date.new(2026, 9, 1))
        expect(account.bank_connection.reload.sync_cursor).to be_nil
      end

      it "clears the marker when the date moves later, too" do
        account.change_read_from(Date.new(2026, 10, 2))

        expect(account.bank_connection.reload.sync_cursor).to be_nil
      end

      it "keeps the marker when the date is set to what it already is, which changes nothing" do
        expect(account.change_read_from(Date.new(2026, 10, 1))).to be(true)

        expect(account.bank_connection.reload.sync_cursor).to eq("2026-10-05T12:00:00Z")
      end

      it "keeps the date and the marker when the new date can't be used, and the reasons are on the Account" do
        expect(account.change_read_from(nil)).to be(false)
        expect(account.errors.full_messages).to eq([ "Read from can't be blank" ])
        expect(account.change_read_from(Date.new(1989, 12, 31))).to be(false)
        expect(account.errors.full_messages).to eq([ "Read from can't be before 1990" ])

        expect(account.reload.read_from).to eq(Date.new(2026, 10, 1))
        expect(account.bank_connection.reload.sync_cursor).to eq("2026-10-05T12:00:00Z")
      end

      it "keeps the marker when anything else about the Account changes" do
        account.update!(name: "Shared")

        expect(account.bank_connection.reload.sync_cursor).to eq("2026-10-05T12:00:00Z")
      end

      it "works when the key the connection's token was encrypted under has been lost, since it never reads the token" do
        garbage = { "p" => Base64.strict_encode64("not-the-payload"), "h" => { "iv" => Base64.strict_encode64("0123456789ab"), "at" => Base64.strict_encode64("0123456789abcdef") } }.to_json
        Budget::BankConnection.connection.execute(Budget::BankConnection.sanitize_sql_array([ "UPDATE budget_bank_connections SET access_token = ? WHERE id = ?", garbage, account.bank_connection_id ]))
        stuck = Budget::Account.find(account.id)

        expect(stuck.change_read_from(Date.new(2026, 9, 1))).to be(true)

        expect(Budget::Account.find(account.id).read_from).to eq(Date.new(2026, 9, 1))
        expect(Budget::BankConnection.find(account.bank_connection_id).sync_cursor).to be_nil
      end
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
