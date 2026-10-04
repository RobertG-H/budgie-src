# What a person can set on a CSV format, which is never the budget it belongs to. The builder's form also sends the sample
# file it was built from, which isn't one of them: it's only ever read for the preview, and is never kept.
module CsvFormatParams
  extend ActiveSupport::Concern

  private
    def csv_format_params
      params.expect(csv_format: [ :name, :rows_to_skip, :column_count, :date_column, :date_format, :description_columns, :amount_style,
                                  :amount_column, :money_in_column, :money_out_column, :direction_column, :money_in_value, :invert_sign ])
    end
end
