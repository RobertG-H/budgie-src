class AddLimitsToBudgetCsvFormats < ActiveRecord::Migration[8.1]
  def change
    # More than any bank's file has, so that a silly number is refused instead of overflowing a column. The model says the same.
    add_check_constraint :budget_csv_formats, "column_count <= 100", name: "budget_csv_formats_column_count_at_most_100"
    add_check_constraint :budget_csv_formats, "rows_to_skip <= 1000", name: "budget_csv_formats_rows_to_skip_at_most_1000"
  end
end
