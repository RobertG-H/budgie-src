require "rails_helper"

RSpec.describe Budget::Account, type: :model do
  subject { build(:budget_account) }

  it { is_expected.to belong_to(:budget) }
  it { is_expected.to have_many(:bank_transactions).class_name("Budget::BankTransaction").dependent(:restrict_with_error) }
  it { is_expected.to have_many(:imports).class_name("Budget::Import").dependent(:destroy) }

  it "uses the budget_accounts table, and is named without the Budget prefix in routes and params" do
    expect(Budget::Account.table_name).to eq("budget_accounts")
    expect(Budget::Account.model_name).to have_attributes(route_key: "accounts", param_key: "account")
  end

  it "has no balance, currency, kind or last four digits, since Budgie doesn't track what's in it" do
    expect(Budget::Account.column_names).to contain_exactly("id", "budget_id", "name", "created_at", "updated_at")
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

    %w[ budget_id name ].each do |column|
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
