class AddSyncColumnsToBudgetBankTransactions < ActiveRecord::Migration[8.1]
  def change
    # What a bank transaction brought in by a sync has instead of an Import (the `roadmap` issue #86, built here for Splitwise): the provider's id for
    # it, which says which row it is in its Account (an Import's rows are told apart by their content key and occurrence, ADR 0010), and when it went
    # from the provider. Both are nullable, which is the importer tables' nulls where absence is real: every row there is has neither.
    add_column :budget_bank_transactions, :external_id, :string
    add_column :budget_bank_transactions, :removed_at, :datetime

    # A synced row has no Import: Undo and an Account's latest Import never reach it. A row has its Import or its external id, so it always says where it came from.
    change_column_null :budget_bank_transactions, :import_id, true

    # One row for each external id in an Account. Nulls are left out, so any number of an Import's rows have none.
    add_index :budget_bank_transactions, [ :account_id, :external_id ], unique: true, where: "external_id IS NOT NULL", name: "index_budget_bank_transactions_on_account_and_external_id"
    add_check_constraint :budget_bank_transactions, "import_id IS NOT NULL OR external_id IS NOT NULL", name: "budget_bank_transactions_import_or_external_id"
    add_check_constraint :budget_bank_transactions, "external_id IS NULL OR btrim(external_id) <> ''", name: "budget_bank_transactions_external_id_not_blank"
  end
end
