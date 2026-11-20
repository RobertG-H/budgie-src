class AddPlaidToBudgetBankConnections < ActiveRecord::Migration[8.1]
  # A bank connected through Plaid (ADR 0018): one Plaid Item is one connection, whose `login_id` is the Item's id and `login_name` the bank's name, with the
  # bank's Plaid id beside them, which the duplicate check before an exchange compares. Each of its accounts that becomes an Account keeps Plaid's name and mask
  # for it, which that check compares too, and which the Account's page shows (the ADR 0001 addendum). Neither is anything an Account that's never been synced has.
  def change
    remove_check_constraint :budget_bank_connections, "provider IN ('splitwise')", name: "budget_bank_connections_provider_known"
    add_check_constraint :budget_bank_connections, "provider IN ('splitwise', 'plaid')", name: "budget_bank_connections_provider_known"

    add_column :budget_bank_connections, :institution_id, :string
    add_check_constraint :budget_bank_connections, "provider <> 'plaid' OR (institution_id IS NOT NULL AND btrim(institution_id) <> '')",
      name: "budget_bank_connections_plaid_has_institution"

    add_column :budget_accounts, :external_name, :string
    add_column :budget_accounts, :external_mask, :string
    add_check_constraint :budget_accounts, "bank_connection_id IS NOT NULL OR (external_name IS NULL AND external_mask IS NULL)",
      name: "budget_accounts_external_name_when_synced"
  end
end
