class AddFileSummaryToBudgetImports < ActiveRecord::Migration[8.1]
  def change
    # What the file held, worked out when it was read, so that the Import's summary can say it later without the file, which isn't
    # kept: the dates it spans, how many rows were money in and how many money out and what each adds up to, and its first row as
    # the CSV format read it. Rows of 0 aren't in any of it. A file with nothing but rows of 0 has no dates and no first row.
    add_column :budget_imports, :earliest_date, :date
    add_column :budget_imports, :latest_date, :date
    add_column :budget_imports, :money_in_count, :integer, null: false, default: 0
    add_column :budget_imports, :money_in_total, :decimal, precision: 20, scale: 2, null: false, default: 0
    add_column :budget_imports, :money_out_count, :integer, null: false, default: 0
    add_column :budget_imports, :money_out_total, :decimal, precision: 20, scale: 2, null: false, default: 0
    add_column :budget_imports, :first_row_date, :date
    add_column :budget_imports, :first_row_description, :string
    add_column :budget_imports, :first_row_amount, :decimal, precision: 15, scale: 2

    # An Import from before this was kept can only say what it added, since the rows it skipped as duplicates weren't kept either.
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE budget_imports SET earliest_date = figures.earliest_date, latest_date = figures.latest_date,
            money_in_count = figures.money_in_count, money_in_total = figures.money_in_total,
            money_out_count = figures.money_out_count, money_out_total = figures.money_out_total
          FROM (
            SELECT import_id, MIN(date) AS earliest_date, MAX(date) AS latest_date,
              COUNT(*) FILTER (WHERE amount > 0) AS money_in_count, COALESCE(SUM(amount) FILTER (WHERE amount > 0), 0) AS money_in_total,
              COUNT(*) FILTER (WHERE amount < 0) AS money_out_count, COALESCE(SUM(amount) FILTER (WHERE amount < 0), 0) AS money_out_total
            FROM budget_bank_transactions GROUP BY import_id
          ) AS figures WHERE figures.import_id = budget_imports.id
        SQL
        execute <<~SQL.squish
          UPDATE budget_imports SET first_row_date = first_rows.date, first_row_description = first_rows.description, first_row_amount = first_rows.amount
          FROM (
            SELECT DISTINCT ON (import_id) import_id, date, description, amount FROM budget_bank_transactions ORDER BY import_id, id
          ) AS first_rows WHERE first_rows.import_id = budget_imports.id
        SQL
      end
    end

    add_check_constraint :budget_imports, "money_in_count >= 0 AND money_out_count >= 0", name: "budget_imports_money_counts_not_negative"
    add_check_constraint :budget_imports, "(money_in_count = 0) = (money_in_total = 0) AND money_in_total >= 0", name: "budget_imports_money_in_total_matches_count"
    add_check_constraint :budget_imports, "(money_out_count = 0) = (money_out_total = 0) AND money_out_total <= 0", name: "budget_imports_money_out_total_matches_count"
    # The dates and the first row are there when the file had a row that wasn't of 0, and not otherwise.
    add_check_constraint :budget_imports, <<~SQL.squish, name: "budget_imports_dates_match_rows"
      (earliest_date IS NULL) = (money_in_count + money_out_count = 0) AND (latest_date IS NULL) = (earliest_date IS NULL)
      AND (earliest_date IS NULL OR earliest_date <= latest_date)
    SQL
    add_check_constraint :budget_imports, <<~SQL.squish, name: "budget_imports_first_row_matches_rows"
      (first_row_date IS NULL) = (money_in_count + money_out_count = 0)
      AND (first_row_description IS NULL) = (first_row_date IS NULL) AND (first_row_amount IS NULL) = (first_row_date IS NULL)
      AND (first_row_description IS NULL OR btrim(first_row_description) <> '') AND (first_row_amount IS NULL OR first_row_amount <> 0)
    SQL
  end
end
