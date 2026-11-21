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

    # What only a Splitwise connection does (Reconnect, which sends the person to sign in to Splitwise): for a bank's, which has its own Reconnect, it's a 404.
    def require_splitwise_connection
      raise ActiveRecord::RecordNotFound unless @connection.splitwise?
    end

    # What only a bank's connection does through Plaid's update mode (Reconnect and Choose accounts): another kind of connection is a 404, and it needs Plaid set up
    # here and turned on for the budget's person (PlaidApi.available_to?), and a token to open Link with, which a disconnected connection no longer has.
    def require_connected_plaid
      raise ActiveRecord::RecordNotFound unless @connection.plaid?

      if !PlaidApi.available_to?(Current.budget)
        redirect_to account_path(@account), alert: "Connecting a bank isn't set up here."
      elsif @connection.disconnected?
        redirect_to account_path(@account), alert: "#{@connection.name} isn't connected any more, so nothing was changed."
      end
    end

    # A link token for Plaid Link's update mode on the connection. Its key being lost, which a token can't be read without, is said on the Account's page.
    def update_link_token(account_selection: false)
      PlaidApi.client.create_update_link_token(access_token: @connection.access_token, client_user_id: Current.budget.id, account_selection: account_selection)
    end
end
