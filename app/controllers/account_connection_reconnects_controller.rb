# Reconnect for an Account synced from a bank through Plaid (ADR 0018): a page that opens Plaid Link in update mode, where the person signs in to the bank again, and
# where Link says it finished (create). Update mode keeps the Item, its account ids and its access token, so nothing is exchanged and nothing secret is sent back:
# the connection works again once Plaid answers `/accounts/get` with its token, and only then is needs-reconnect cleared. Leaving Link changes nothing. It reaches the
# whole connection, so every Account synced from it. Another user's Account, one that isn't synced from a bank, and one whose connection was disconnected aren't
# reconnected here.
class AccountConnectionReconnectsController < ApplicationController
  include SyncedAccountScoped

  before_action :require_connected_plaid

  rescue_from ActiveRecord::Encryption::Errors::Decryption do
    redirect_to account_path(@account), alert: "Budgie can't read the saved connection to #{@connection.name}, so it can't be reconnected."
  end

  # The link token is made as the page renders and lasts 30 minutes, so the page is never cached.
  def new
    @link_token = update_link_token
  rescue PlaidApi::Error => error
    redirect_to account_path(@account), alert: "#{@connection.name} wasn't reconnected. #{error.message}"
  end

  # Holding the connection's row lock, as a sync does, so a sync finding it stopped working can't be overwritten by this clearing it.
  def create
    @connection.with_lock do
      PlaidApi.client.accounts(@connection.access_token)
      @connection.clear_needs_reconnect!
    end
    redirect_to account_path(@account), status: :see_other, notice: "Reconnected #{@connection.name}."
  rescue PlaidApi::Error => error
    redirect_to account_path(@account), status: :see_other, alert: refusal(error)
  end

  private
    # The bank still won't answer: a connection that seemed to work is marked as needing reconnecting, as a sync would find. Anything else, such as Plaid not
    # being reached, changes nothing, and a connection that works isn't said to need reconnecting.
    def refusal(error)
      @connection.needs_reconnect! if SyncPlaid::NEEDS_RECONNECT.include?(error.error_code)
      return "#{@connection.name} still needs reconnecting." if @connection.needs_reconnect?

      "#{@connection.name} wasn't reconnected. #{error.message}"
    end
end
