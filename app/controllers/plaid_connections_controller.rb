# Connecting a bank through Plaid (ADR 0018), the first of two pages: it opens Plaid Link, where the person signs in to their bank and chooses which accounts to
# share, and what Link gives back when they finish is sent here by the `plaid-link` Stimulus controller and kept in the session for the next page, where they choose
# what each account becomes (PlaidChoicesController). Nothing is exchanged and nothing is made here, so leaving after Link keeps nothing.
class PlaidConnectionsController < ApplicationController
  include PlaidLinking

  # The link token is made as the page renders, so Link opens at once. It's never kept, and the page is never cached, so one that has expired never comes back.
  def new
    @link_token = PlaidApi.client.create_link_token(client_user_id: Current.budget.id)
  rescue PlaidApi::Error => error
    redirect_to accounts_path, alert: "Nothing was connected. #{error.message}"
  end

  # What Link's `onSuccess` sent, which is trusted only to skip an exchange: what's stored comes from Plaid once the choice is submitted.
  def create
    link = PendingPlaidLink.from_params(link_params, budget: Current.budget)

    if link.nil?
      redirect_to new_plaid_connection_path, alert: "Plaid didn't say which accounts were shared, so nothing was connected. Try again."
    elsif link.too_many_accounts?
      redirect_to accounts_path, alert: "Nothing was connected, since more than #{PendingPlaidLink::MAX_ACCOUNTS} accounts were shared. " \
        "Connect again and share #{PendingPlaidLink::MAX_ACCOUNTS} or fewer."
    else
      keep_pending_link(link)
      redirect_to plaid_choice_path
    end
  end

  private
    def link_params
      params.fetch(:plaid_link, {}).permit(:public_token, :institution_id, :institution_name, accounts: [ :id, :name, :mask, :subtype ])
    end
end
