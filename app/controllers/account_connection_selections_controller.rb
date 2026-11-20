# Choose accounts for an Account synced from a bank through Plaid (ADR 0018): a page that opens Plaid Link in update mode with account selection, where the person
# changes which of the bank's accounts are shared, and where Link's `onSuccess` sends the whole selection (create). It's kept in the session for the choice page
# (PlaidChoicesController), as Connect's is, when a selected account isn't an Account yet; when every one is, it's saved straight away (ChoosePlaidAccounts),
# since there's nothing to ask. Leaving Link changes nothing. It reaches the whole connection, so every Account synced from it.
class AccountConnectionSelectionsController < ApplicationController
  include SyncedAccountScoped

  before_action :require_connected_plaid

  # For keeping what Link sent in the session. Included after the check above, so another user's Account is a 404 before anything else; its own check that Plaid is
  # set up has already passed by then.
  include PlaidLinking

  rescue_from ActiveRecord::Encryption::Errors::Decryption do
    redirect_to account_path(@account), alert: "Budgie can't read the saved connection to #{@connection.name}, so its accounts can't be chosen."
  end

  # The link token is made as the page renders and lasts 30 minutes, so the page is never cached.
  def new
    @link_token = update_link_token(account_selection: true)
  rescue PlaidApi::Error => error
    redirect_to account_path(@account), alert: "Nothing was changed. #{error.message}"
  end

  def create
    link = PendingPlaidLink.for_selection(link_params, account: @account)

    if link.nil?
      redirect_to new_account_connection_selection_path(@account), alert: "Plaid didn't say which accounts are shared, so nothing was changed. Try again."
    elsif link.too_many_accounts?
      redirect_to account_path(@account), alert: "Nothing was changed, since more than #{PendingPlaidLink::MAX_ACCOUNTS} accounts were shared. " \
        "Choose accounts again and share #{PendingPlaidLink::MAX_ACCOUNTS} or fewer."
    else
      choose(link)
    end
  end

  private
    # Only what an account is: the bank, the token and the budget are never params.
    def link_params
      params.fetch(:plaid_link, {}).permit(accounts: [ :id, :name, :mask, :subtype ])
    end

    def choose(link)
      chooser = ChoosePlaidAccounts.new(connection: @connection, link: link)
      if chooser.new_accounts.any?
        keep_pending_link(link)
        return redirect_to(plaid_choice_path)
      end

      result = chooser.call([])
      flash_type = result.saved? ? :notice : :alert
      redirect_to account_path(@account), flash_type => (result.notice || result.alert)
    end
end
