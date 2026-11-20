class AddUnsharedAtToBudgetAccounts < ActiveRecord::Migration[8.1]
  # When a bank's account stopped being shared through Plaid, because the person de-selected it in Choose accounts (ADR 0018): the Account keeps its bank
  # transactions and stays synced, and gets nothing new. Null while it's shared, and on every Account that isn't synced, which has nothing to stop sharing.
  def change
    add_column :budget_accounts, :unshared_at, :datetime
    add_check_constraint :budget_accounts, "bank_connection_id IS NOT NULL OR unshared_at IS NULL", name: "budget_accounts_unshared_when_synced"
  end
end
