class AddFilesWithRulesToBudgetAccounts < ActiveRecord::Migration[8.1]
  def change
    # Whether Filing rules act on the Account's bank transactions (ADR 0012). On, so every Account that's there keeps working as it does now; one
    # that's turned off has every bank transaction wait for a person. Not null, like the core tables' columns: it's a fact about every Account,
    # and not an absence.
    add_column :budget_accounts, :files_with_rules, :boolean, null: false, default: true
  end
end
