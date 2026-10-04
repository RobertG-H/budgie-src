class CreateBudgetAccountsImportsAndBankTransactions < ActiveRecord::Migration[8.1]
  def change
    # A real bank or card account that bank transactions come from. It has no balance, no currency (it uses its budget's),
    # no kind and no last four digits, because Budgie doesn't track what's in it (ADR 0001).
    create_table :budget_accounts do |t|
      t.references :budget, null: false, index: false, foreign_key: { on_delete: :restrict }
      t.string :name, null: false

      t.timestamps
    end

    add_index :budget_accounts, "budget_id, lower(name)", unique: true, name: "index_budget_accounts_on_budget_id_and_lower_name"
    add_check_constraint :budget_accounts, "btrim(name) <> ''", name: "budget_accounts_name_not_blank"

    # One CSV file read into one Account. The file isn't kept, and there's no user_id, because authorship is decided once
    # for every record. `created_at` is when it ran.
    create_table :budget_imports do |t|
      t.references :account, null: false, index: false, foreign_key: { to_table: :budget_accounts, on_delete: :restrict }
      t.references :csv_format, null: false, foreign_key: { to_table: :budget_csv_formats, on_delete: :restrict }
      t.string :file_name, null: false
      # Rows of the file that were already in the Account (ADR 0010), and rows of 0, which aren't kept. Neither is in the
      # Account, so the summary can only say them from here.
      t.integer :duplicates_skipped, null: false, default: 0
      t.integer :zero_rows_skipped, null: false, default: 0

      t.timestamps
    end

    # Serves finding an Account's latest Import.
    add_index :budget_imports, [ :account_id, :created_at ]
    add_check_constraint :budget_imports, "btrim(file_name) <> ''", name: "budget_imports_file_name_not_blank"
    add_check_constraint :budget_imports, "duplicates_skipped >= 0", name: "budget_imports_duplicates_skipped_not_negative"
    add_check_constraint :budget_imports, "zero_rows_skipped >= 0", name: "budget_imports_zero_rows_skipped_not_negative"

    # The bank's record of money moving in or out of an Account. It belongs to its budget through its Account, so it has no
    # budget_id. Its amount is signed (ADR 0009).
    create_table :budget_bank_transactions do |t|
      t.references :account, null: false, index: false, foreign_key: { to_table: :budget_accounts, on_delete: :restrict }
      # Not null while an Import is the only way one is made. Bank sync will make it nullable.
      t.references :import, null: false, foreign_key: { to_table: :budget_imports, on_delete: :restrict }
      t.date :date, null: false
      t.string :description, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      # What identifies a row in its Account (ADR 0010): a digest of the Account, date, signed amount and description as the
      # row first looked, with an occurrence number for each time the same row is in the Account. Both are written once, at
      # insert, and never recomputed, because they record how the row first looked.
      t.string :content_key, null: false
      t.integer :occurrence, null: false
      # The description as a Filing rule or a Guess reads it: trimmed, whitespace collapsed and case folded. Unlike the key it
      # follows the description, which bank sync updates in place, and it's stored, so it can be matched and indexed without
      # a backfill.
      t.virtual :normalized_description, type: :text, stored: true, as: "lower(regexp_replace(btrim(description), '\\s+', ' ', 'g'))"

      t.timestamps
    end

    add_index :budget_bank_transactions, [ :account_id, :content_key, :occurrence ], unique: true, name: "index_budget_bank_transactions_on_content_key_and_occurrence"
    # Serves an Account's page, which lists its bank transactions newest first.
    add_index :budget_bank_transactions, [ :account_id, :date, :id ]
    add_check_constraint :budget_bank_transactions, "amount <> 0", name: "budget_bank_transactions_amount_not_zero"
    add_check_constraint :budget_bank_transactions, "btrim(description) <> ''", name: "budget_bank_transactions_description_not_blank"
    add_check_constraint :budget_bank_transactions, "content_key ~ '^[0-9a-f]{64}$'", name: "budget_bank_transactions_content_key_format"
    add_check_constraint :budget_bank_transactions, "occurrence >= 1", name: "budget_bank_transactions_occurrence_positive"
  end
end
