# A CSV format's date is read in an order (year, month, day; month, day, year; or day, month, year) instead of one exact
# format, so any separator, a month as a word, a two-digit year and a time after the date all read (see
# Budget::CsvFormat::DateOrder). Each of the four formats there were becomes the order it was written in, and every date
# that read before reads as the same date now.
class ReplaceDateFormatWithDateOrderOnBudgetCsvFormats < ActiveRecord::Migration[8.1]
  FORMATS_TO_ORDERS = { "YYYY-MM-DD" => "year_month_day", "YYYYMMDD" => "year_month_day",
                        "MM/DD/YYYY" => "month_day_year", "DD/MM/YYYY" => "day_month_year" }.freeze

  def up
    remove_check_constraint :budget_csv_formats, name: "budget_csv_formats_date_format_known"
    rename_column :budget_csv_formats, :date_format, :date_order
    execute <<~SQL.squish
      UPDATE budget_csv_formats SET date_order = CASE date_order
        #{FORMATS_TO_ORDERS.map { |format, order| "WHEN #{connection.quote(format)} THEN #{connection.quote(order)}" }.join(" ")}
      END
    SQL
    add_check_constraint :budget_csv_formats, "date_order IN ('year_month_day', 'month_day_year', 'day_month_year')",
      name: "budget_csv_formats_date_order_known"
  end

  # Going back can't tell which of the two year-first formats a format was, so it takes the one with dashes.
  def down
    remove_check_constraint :budget_csv_formats, name: "budget_csv_formats_date_order_known"
    execute <<~SQL.squish
      UPDATE budget_csv_formats SET date_order = CASE date_order
        WHEN 'year_month_day' THEN 'YYYY-MM-DD' WHEN 'month_day_year' THEN 'MM/DD/YYYY' WHEN 'day_month_year' THEN 'DD/MM/YYYY'
      END
    SQL
    rename_column :budget_csv_formats, :date_order, :date_format
    add_check_constraint :budget_csv_formats, "date_format IN ('YYYY-MM-DD', 'MM/DD/YYYY', 'DD/MM/YYYY', 'YYYYMMDD')",
      name: "budget_csv_formats_date_format_known"
  end
end
