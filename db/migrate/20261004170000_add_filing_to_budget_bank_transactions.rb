class AddFilingToBudgetBankTransactions < ActiveRecord::Migration[8.1]
  def change
    # When a bank transaction was ignored, which is for one that Budgie won't file, such as a card payment between a person's
    # own accounts. Null while it isn't: most aren't. Whether it's ignored, filed or unfiled is derived, never stored.
    add_column :budget_bank_transactions, :ignored_at, :datetime

    # One link table per kind of record a bank transaction can be filed as, so that the core tables stay free of import columns
    # (ADR 0002). A record comes from at most one bank transaction, which the unique index says, and the foreign keys are
    # restrict, so the records' models delete their link before they go.
    create_table :budget_deposit_links do |t|
      t.references :bank_transaction, null: false, foreign_key: { to_table: :budget_bank_transactions, on_delete: :restrict }
      t.references :deposit, null: false, index: { unique: true }, foreign_key: { to_table: :budget_deposits, on_delete: :restrict }

      t.timestamps
    end

    create_table :budget_spend_links do |t|
      t.references :bank_transaction, null: false, foreign_key: { to_table: :budget_bank_transactions, on_delete: :restrict }
      t.references :spend, null: false, index: { unique: true }, foreign_key: { to_table: :budget_spends, on_delete: :restrict }

      t.timestamps
    end

    create_table :budget_refund_links do |t|
      t.references :bank_transaction, null: false, foreign_key: { to_table: :budget_bank_transactions, on_delete: :restrict }
      t.references :refund, null: false, index: { unique: true }, foreign_key: { to_table: :budget_refunds, on_delete: :restrict }

      t.timestamps
    end
  end
end
