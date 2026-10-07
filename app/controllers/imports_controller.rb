# Importing a CSV file: the form, and the Import it makes. The Account's own page links to its form (nested under the Account, so the Account
# is fixed), and the header's Import leads to the whole form (`/imports/new`), where the Account is chosen along with the file and the CSV format.
# Either way the file is read in the request, and what it did is the Import's summary.
class ImportsController < ApplicationController
  before_action :set_account, only: %i[ new create ]
  before_action :refuse_synced_account, only: %i[ new create ]
  before_action :set_import, only: %i[ show destroy ]

  # The CSV format of the Account's most recent Import is chosen to start with, since it's most likely the same bank's, and before its
  # first Import, the Account's default, if it has one. The whole form starts with nothing chosen.
  def new
    @import = Budget::Import.new(account: @account, csv_format: @account && (@account.latest_import&.csv_format || @account.default_csv_format))
  end

  # The file is read in the request: if it can't be read nothing is created, and the form comes back with the first row
  # that can't be, by its line. Otherwise the Import is made, and what the file held and what it added is its summary.
  def create
    @import = Budget::Import.new(account: @account, csv_format: csv_format, file_name: file&.original_filename)

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
    # The Account an Import is for, found through the user's budget. In the Account's own routes it's the Account of the page, and another user's
    # is a 404. On the whole form it's the one chosen, and another budget's, or none, is no Account, which the Import refuses like any other missing
    # field: "Account can't be blank".
    def set_account
      @account_fixed = params[:account_id].present?
      @account = if @account_fixed
        Current.budget.accounts.find(params[:account_id])
      else
        Current.budget.accounts.find_by(id: submitted_account_id)
      end
    end

    # A synced Account, such as Splitwise's, takes no Import, whichever way it's asked for: its page has none and the form's Account select leaves it out, so this
    # is only for a crafted request. The model refuses it too (Budget::Import).
    def refuse_synced_account
      return unless @account&.synced?

      redirect_to account_path(@account), alert: "#{@account.name} #{@account.import_refusal}."
    end

    # What the whole form sends as the Account, which is only ever an id of the budget's own, and nothing at all for a form that isn't sent.
    def submitted_account_id
      params.dig(:import, :account_id).to_s.presence if params[:import].respond_to?(:key?)
    end

    # Found through the user's budget, by way of its Account, so another user's Import is a 404.
    def set_import
      @import = Current.budget.imports.find(params[:id])
    end

    def import_params
      @import_params ||= params.expect(import: [ :csv_format_id, :account_id, :file ])
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
