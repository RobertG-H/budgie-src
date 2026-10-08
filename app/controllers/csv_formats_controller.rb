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

    if save_with_sample
      redirect_to csv_formats_path, notice: "CSV format added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    @csv_format.assign_attributes(csv_format_params)

    if save_with_sample
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
    # Saves the format with the column count of the sample that was sent with the form, if one was, which is the sample's whatever the
    # form's own say: the preview fills it in as the form changes, and a form without JavaScript, or one sent before the preview
    # answered, has none. A sample that can't be read is refused, with why. Without one, the format keeps the column count it has.
    # A date order that wasn't chosen is chosen from the sample, as the preview would have.
    def save_with_sample
      sample = read_sample(@csv_format)
      @csv_format.column_count = sample.column_count if sample&.column_count
      @csv_format.choose_date_order(sample)
      return @csv_format.save unless sample&.refusal

      @csv_format.valid?
      @csv_format.errors.add(:base, sample.refusal.message)
      false
    end

    # Found through the user's budget, so another user's CSV format is a 404.
    def set_csv_format
      @csv_format = Current.budget.csv_formats.find(params[:id])
    end
end
