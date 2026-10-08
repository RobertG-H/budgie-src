# What a person can set on a CSV format, which is never the budget it belongs to, and the sample file the builder's form sends with
# it. The sample isn't one of the choices: it's only ever read, for the preview and for the format's column count, and is never kept.
module CsvFormatParams
  extend ActiveSupport::Concern

  private
    def csv_format_params
      params.expect(csv_format: [ :name, :rows_to_skip, :column_count, :date_column, :date_order, :description_columns, :amount_style,
                                  :amount_column, :money_in_column, :money_out_column, :direction_column, :money_in_value, :invert_sign ])
    end

    # The sample that was sent, if one was: anything else in its place is no sample. The rows to skip are the format's as it stands.
    def read_sample(csv_format)
      file = params.dig(:csv_format, :sample)
      return unless file.respond_to?(:original_filename)

      Budget::CsvFormat::Sample.new(file, rows_to_skip: csv_format.rows_to_skip.to_i.clamp(0, Budget::CsvFormat::MAX_ROWS_TO_SKIP))
    end
end
