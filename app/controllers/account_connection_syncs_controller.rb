# Sync now: brings a synced Account's expenses in by hand, which the hourly job (SyncBankConnectionsJob) also does, and says what it did (SyncSplitwise). It's found
# through the budget's Accounts, so another user's Account is a 404, and so is one that isn't synced. A sync that can't be done, because Splitwise stopped accepting the
# sign-in or is limiting how often it can be asked, changes nothing and says so, with where to go from there.
class AccountConnectionSyncsController < ApplicationController
  include SyncedAccountScoped

  before_action :require_splitwise_configured

  def create
    result = SyncSplitwise.call(@connection)

    if result.success?
      redirect_to account_path(@account), status: :see_other, notice: result.notice
    else
      redirect_to account_path(@account), status: :see_other, alert: result.failure
    end
  rescue => error
    # Anything else that goes wrong is logged with the connection's id, as the hourly job does, and its sync was rolled back whole: nothing was changed.
    Rails.logger.error "Couldn't sync connection #{@connection.id}: #{error.class}: #{error.message}"
    redirect_to account_path(@account), status: :see_other, alert: "Something went wrong, so nothing was synced. Try again later."
  end

  private
    # A token can't be read without Splitwise's keys, which not every host has.
    def require_splitwise_configured
      redirect_to accounts_path, alert: "Splitwise isn't set up here, so it can't be synced." unless Splitwise.configured?
    end
end
