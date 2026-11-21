# What connecting a bank through Plaid's two pages have in common: they're only there where Plaid is set up, and what Plaid Link gave back is kept in the
# session between them (PendingPlaidLink), for this budget and for 30 minutes, until the choice is submitted or cancelled.
module PlaidLinking
  extend ActiveSupport::Concern

  included do
    before_action :require_plaid
  end

  private
    # Connecting needs Plaid's client id, secret and environment, and the keys to keep the token under, which only some hosts have, and Plaid turned on for the
    # budget's person (PlaidApi.available_to?): without them nothing is offered, and a request for it is turned away.
    def require_plaid
      redirect_to accounts_path, alert: "Connecting a bank isn't set up here." unless PlaidApi.available_to?(Current.budget)
    end

    def keep_pending_link(link)
      session[PendingPlaidLink::SESSION_KEY] = link.to_session
    end

    def pending_link
      PendingPlaidLink.from_session(session[PendingPlaidLink::SESSION_KEY])
    end

    def forget_pending_link
      session.delete(PendingPlaidLink::SESSION_KEY)
    end
end
