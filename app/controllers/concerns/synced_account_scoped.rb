# What the controllers for a synced Account's connection have in common: the Account is found through the budget's, so another user's Account is a 404, and so is
# one that isn't synced, and `@connection` is what it's synced from.
module SyncedAccountScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_account
  end

  private
    def set_account
      @account = Current.budget.accounts.find(params[:account_id])
      @connection = @account.bank_connection or raise ActiveRecord::RecordNotFound
    end

    # What only a Splitwise connection does so far (Sync now, Reconnect, Disconnect): for a bank's, which gets its own in later tickets, it's a 404.
    def require_splitwise_connection
      raise ActiveRecord::RecordNotFound unless @connection.splitwise?
    end
end
