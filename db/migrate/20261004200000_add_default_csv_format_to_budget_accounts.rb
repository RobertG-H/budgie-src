class AddDefaultCsvFormatToBudgetAccounts < ActiveRecord::Migration[8.1]
  # An Account that has Imports is recognised from day one: its default is the CSV format of its latest Import (`created_at`, then `id`). An
  # Account without an Import stays without one. A constant, so that a spec can run the very statement the migration does.
  BACKFILL = <<~SQL.squish
    UPDATE budget_accounts SET default_csv_format_id = latest.csv_format_id
    FROM (
      SELECT DISTINCT ON (account_id) account_id, csv_format_id
      FROM budget_imports
      ORDER BY account_id, created_at DESC, id DESC
    ) AS latest
    WHERE latest.account_id = budget_accounts.id
  SQL

  def change
    # The CSV format an Account's bank's files use, so that an Import from the header can tell which Account a file is for, and the Account's
    # own Import form starts on it before its first Import. Optional: nothing requires an Account to have one, which is the importer tables'
    # nulls where absence is real. Restrict, like every foreign key here: the CSV format's model clears it before the format goes.
    add_reference :budget_accounts, :default_csv_format, null: true, index: true, foreign_key: { to_table: :budget_csv_formats, on_delete: :restrict }

    reversible do |direction|
      direction.up { execute BACKFILL }
    end
  end
end
