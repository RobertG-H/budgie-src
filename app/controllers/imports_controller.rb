class ImportsController < ApplicationController
  before_action :set_account, only: %i[ new create ]

  # The CSV format of the Account's most recent Import is chosen to start with, since it's most likely the same bank's.
  def new
    @import = @account.imports.build(csv_format: @account.latest_import&.csv_format)
  end

  # The file is read in the request: if it can't be read nothing is created, and the form comes back with the first row
  # that can't be, by its line. Otherwise the Import is made, and what it did is its summary.
  def create
    @import = @account.imports.build(csv_format: csv_format, file_name: file&.original_filename)

    if @import.run(file)
      redirect_to import_path(@import)
    else
      render :new, status: :unprocessable_content
    end
  end

  # What the Import did. Found through the user's budget, by way of its Account, so another user's is a 404.
  def show
    @import = Current.budget.imports.find(params[:id])
    @account = @import.account
    @summary = @import.summary
  end

  private
    # Found through the user's budget, so another user's Account is a 404.
    def set_account
      @account = Current.budget.accounts.find(params[:account_id])
    end

    def import_params
      @import_params ||= params.expect(import: [ :csv_format_id, :file ])
    end

    # The CSV format is only ever one of the budget's own: another budget's, or one that doesn't exist, is none, which the
    # Import refuses.
    def csv_format
      Current.budget.csv_formats.find_by(id: import_params[:csv_format_id])
    end

    # The file that was sent, if one was: anything else in its place is no file.
    def file
      import_params[:file] if import_params[:file].respond_to?(:original_filename)
    end
end
