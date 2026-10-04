# How the sample file reads with the CSV format as it's been chosen so far, which the builder asks for each time a choice
# changes. It's sent the whole form, sample included, and answers with the sample's grid and the preview, so nothing about the
# sample is kept between one request and the next.
class CsvFormatPreviewsController < ApplicationController
  include CsvFormatParams

  def create
    @csv_format = build_csv_format
    @sample = read_sample(@csv_format)
    @csv_format.column_count = @sample.column_count if @sample&.column_count
    @preview = Budget::CsvFormat::Preview.new(@csv_format, @sample)

    # Without JavaScript the Preview button sends the form as it is, so the answer is the whole page.
    respond_to do |format|
      format.turbo_stream
      format.html { render @csv_format.persisted? ? "csv_formats/edit" : "csv_formats/new" }
    end
  end

  private
    # The format being built, or the one being edited, which is found through the user's budget so another user's is a 404.
    # Neither is saved: it's only given the choices so far.
    def build_csv_format
      csv_format = params[:csv_format_id].present? ? Current.budget.csv_formats.find(params[:csv_format_id]) : Current.budget.csv_formats.new
      csv_format.tap { |format| format.assign_attributes(csv_format_params) }
    end
end
