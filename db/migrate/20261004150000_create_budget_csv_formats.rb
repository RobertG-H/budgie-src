class CreateBudgetCsvFormats < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_csv_formats do |t|
      t.references :budget, null: false, index: false, foreign_key: { on_delete: :restrict }
      t.string :name, null: false
      # Rows at the top that aren't bank transactions: a header row and any preamble.
      t.integer :rows_to_skip, null: false, default: 0
      # Taken from the sample file the format was built from, which isn't kept. Columns are numbered from 1.
      t.integer :column_count, null: false
      t.integer :date_column, null: false
      t.string :date_format, null: false
      # Joined with a space.
      t.integer :description_columns, array: true, null: false
      t.string :amount_style, null: false
      # Which of these are set depends on the amount style, which the constraints below tie together. The columns a style
      # doesn't use are null, because there's nothing to say about them. A signed amount and a direction style's unsigned
      # amount share a column.
      t.integer :amount_column
      t.integer :money_in_column
      t.integer :money_out_column
      t.integer :direction_column
      # What the direction column holds for money in. Anything else is money out.
      t.string :money_in_value
      # For files where money out is positive, such as a credit card's.
      t.boolean :invert_sign, null: false, default: false

      t.timestamps
    end

    add_index :budget_csv_formats, "budget_id, lower(name)", unique: true, name: "index_budget_csv_formats_on_budget_id_and_lower_name"

    add_check_constraint :budget_csv_formats, "btrim(name) <> ''", name: "budget_csv_formats_name_not_blank"
    add_check_constraint :budget_csv_formats, "rows_to_skip >= 0", name: "budget_csv_formats_rows_to_skip_not_negative"
    add_check_constraint :budget_csv_formats, "column_count >= 1", name: "budget_csv_formats_column_count_positive"
    add_check_constraint :budget_csv_formats, "date_column BETWEEN 1 AND column_count", name: "budget_csv_formats_date_column_within_count"
    add_check_constraint :budget_csv_formats, "date_format IN ('YYYY-MM-DD', 'MM/DD/YYYY', 'DD/MM/YYYY', 'YYYYMMDD')",
      name: "budget_csv_formats_date_format_known"
    add_check_constraint :budget_csv_formats,
      "cardinality(description_columns) >= 1 AND 1 <= ALL (description_columns) AND column_count >= ALL (description_columns)",
      name: "budget_csv_formats_description_columns_within_count"
    add_check_constraint :budget_csv_formats, "amount_style IN ('signed', 'in_and_out', 'direction')", name: "budget_csv_formats_amount_style_known"

    # One signed column; nothing else is used.
    add_check_constraint :budget_csv_formats, <<~SQL.squish, name: "budget_csv_formats_signed_columns"
      amount_style <> 'signed' OR (
        amount_column IS NOT NULL AND amount_column BETWEEN 1 AND column_count
        AND money_in_column IS NULL AND money_out_column IS NULL AND direction_column IS NULL AND money_in_value IS NULL
      )
    SQL
    # Separate money-in and money-out columns, which are different columns.
    add_check_constraint :budget_csv_formats, <<~SQL.squish, name: "budget_csv_formats_in_and_out_columns"
      amount_style <> 'in_and_out' OR (
        money_in_column IS NOT NULL AND money_in_column BETWEEN 1 AND column_count
        AND money_out_column IS NOT NULL AND money_out_column BETWEEN 1 AND column_count
        AND money_in_column <> money_out_column
        AND amount_column IS NULL AND direction_column IS NULL AND money_in_value IS NULL
      )
    SQL
    # One unsigned column, a different column that says which way the money went, and the value that means money in.
    add_check_constraint :budget_csv_formats, <<~SQL.squish, name: "budget_csv_formats_direction_columns"
      amount_style <> 'direction' OR (
        amount_column IS NOT NULL AND amount_column BETWEEN 1 AND column_count
        AND direction_column IS NOT NULL AND direction_column BETWEEN 1 AND column_count
        AND amount_column <> direction_column
        AND money_in_value IS NOT NULL AND btrim(money_in_value) <> ''
        AND money_in_column IS NULL AND money_out_column IS NULL
      )
    SQL
  end
end
