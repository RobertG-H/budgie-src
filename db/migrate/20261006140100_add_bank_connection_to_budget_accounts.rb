class AddBankConnectionToBudgetAccounts < ActiveRecord::Migration[8.1]
  def change
    # The connection an Account is synced from, and the provider's id for it: for Splitwise, the Splitwise user's id, since the Account holds that
    # user's share of every expense. An Account with neither is one Budgie knows only from CSV files, which is every Account there is now.
    # Optional, which is the importer tables' nulls where absence is real. Restrict, like every foreign key here: the connection's model refuses
    # to go while an Account has it, and deleting an Account takes its connection with it when no other Account has it.
    add_reference :budget_accounts, :bank_connection, null: true, index: false, foreign_key: { to_table: :budget_bank_connections, on_delete: :restrict }
    add_column :budget_accounts, :external_account_id, :string

    # One Account for each of a connection's external accounts. Nulls count as different, so any number of Accounts have neither.
    add_index :budget_accounts, [ :bank_connection_id, :external_account_id ], unique: true, name: "index_budget_accounts_on_connection_and_external_id"
    # Both or neither: an Account's external id means nothing without its connection, and a connection's Account is told apart by it.
    add_check_constraint :budget_accounts, "(bank_connection_id IS NULL) = (external_account_id IS NULL)", name: "budget_accounts_connection_with_external_id"
  end
end
