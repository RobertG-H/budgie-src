# Sync now: brings a synced Account's shares or bank transactions in by hand, which the hourly job (SyncBankConnectionsJob) also does, and says what it did, through
# its connection's provider (SyncSplitwise or SyncPlaid). It's found through the budget's Accounts, so another user's Account is a 404, and so is one that isn't
# synced. A sync that can't be done, because the provider stopped accepting the connection or is limiting how often it can be asked, changes nothing and says so,
# with where to go from there. A bank's sync is for its connection, which is every Account it syncs, not only this one.
class AccountConnectionSyncsController < ApplicationController
  include SyncedAccountScoped

  before_action :require_provider_available

  def create
    result = @connection.sync

    if result.success?
      # Whatever its Filing rules filed or ignored is to review (ADR 0017), so the notice links to where it is: for this Account when it's the connection's only
      # one, as a Splitwise Account is, and for every Account otherwise, since a bank's sync files in each of its Accounts.
      if result.filed_by_rules.positive? || result.ignored_by_rules.positive?
        flash[:review_path] = bank_transactions_path(filter: { state: "to_review", account: (@account.id if @connection.login_is_the_account?) }.compact)
      end
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
    # A token can't be read without the provider's keys, which not every host has, and a bank's is synced only for a person who has Plaid turned on.
    def require_provider_available
      redirect_to accounts_path, alert: "#{@connection.provider_name} isn't set up here, so it can't be synced." unless @connection.provider_available?
    end
end
