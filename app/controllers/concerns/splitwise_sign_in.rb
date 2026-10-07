# Sending a person to Splitwise to sign in, for the two places that do: connecting it (SplitwiseConnectionsController) and reconnecting an Account's
# connection (AccountConnectionsController). What the person asked for is kept in the session with a random `state` and the budget it was for, and the
# callback (SplitwiseCallbacksController) takes it back out, once: it refuses a state that isn't the one that was sent, so a callback that wasn't asked
# for does nothing. Nothing about the connection is kept anywhere until the callback makes it.
module SplitwiseSignIn
  extend ActiveSupport::Concern

  SESSION_KEY = "splitwise_sign_in".freeze

  private
    # Connecting needs Splitwise's client id and secret, and a key to keep the token under, which only some hosts have: without them nothing is
    # offered, and a request for it is turned away, rather than sending a person to Splitwise to be told afterwards.
    def require_splitwise
      redirect_to accounts_path, alert: "Splitwise isn't set up here, so it can't be connected." unless Splitwise.configured?
    end

    # `intent` is what the callback needs to finish: the Account's name and the date to read from for a new connection, or the Account to reconnect.
    # The session is a signed, encrypted cookie, so the person can't change any of it. Turbo can't follow a redirect to another site, so the forms
    # that lead here have Turbo off.
    def send_to_splitwise(**intent)
      state = SecureRandom.hex(24)
      session[SESSION_KEY] = intent.merge(state: state, budget_id: Current.budget.id).stringify_keys

      redirect_to Splitwise.client.authorization_url(redirect_uri: splitwise_callback_url, state: state), allow_other_host: true
    end
end
