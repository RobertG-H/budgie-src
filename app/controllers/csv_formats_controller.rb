class CsvFormatsController < ApplicationController
  include CsvFormatParams

  before_action :set_csv_format, only: %i[ edit update destroy ]

  def index
    @csv_formats = Current.budget.csv_formats.alphabetical
  end

  def new
    @csv_format = Current.budget.csv_formats.new(amount_style: "signed")
  end

  def create
    @csv_format = Current.budget.csv_formats.new(csv_format_params)

    if @csv_format.save
      redirect_to csv_formats_path, notice: "CSV format added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @csv_format.update(csv_format_params)
      redirect_to csv_formats_path, notice: "CSV format updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  # A CSV format that an Import used can't be deleted: its edit page says why, and stays.
  def destroy
    if @csv_format.destroy
      redirect_to csv_formats_path, status: :see_other, notice: "CSV format deleted."
    else
      redirect_to edit_csv_format_path(@csv_format), status: :see_other, alert: @csv_format.errors.full_messages.to_sentence
    end
  end

  private
    # Found through the user's budget, so another user's CSV format is a 404.
    def set_csv_format
      @csv_format = Current.budget.csv_formats.find(params[:id])
    end
end
