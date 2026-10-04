class ImportsController < ApplicationController
  before_action :set_account, only: %i[ new create ]
  before_action :set_import, only: %i[ show destroy ]

  # The CSV format of the Account's most recent Import is chosen to start with, since it's most likely the same bank's.
  def new
    @import = @account.imports.build(csv_format: @account.latest_import&.csv_format)
  end

  # The file is read in the request: if it can't be read nothing is created, and the form comes back with the first row
  # that can't be, by its line. Otherwise the Import is made, and what the file held and what it added is its summary.
  def create
    @import = @account.imports.build(csv_format: csv_format, file_name: file&.original_filename)

    if @import.run(file)
      redirect_to import_path(@import)
    else
      render :new, status: :unprocessable_content
    end
  end

  # What the Import did, and whether it can still be undone, and if it can't, why.
  def show
    @account = @import.account
    @undo_refusal = @import.undo_refusal
  end

  # Takes back the Account's latest Import, within 24 hours of it running (ADR 0011). When it can't be, the reason is the alert
  # on its summary, which is where Undo was asked for, and nothing changes.
  def destroy
    @import.undo
    redirect_to account_path(@import.account), status: :see_other, notice: "Import undone."
  rescue Budget::Import::Refused => refusal
    redirect_to import_path(@import), status: :see_other, alert: refusal.message
  end

  private
    # Found through the user's budget, so another user's Account is a 404.
    def set_account
      @account = Current.budget.accounts.find(params[:account_id])
    end

    # Found through the user's budget, by way of its Account, so another user's Import is a 404.
    def set_import
      @import = Current.budget.imports.find(params[:id])
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
