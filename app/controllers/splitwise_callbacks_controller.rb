# Where Splitwise sends the person back to after they've signed in, or declined. This is the OAuth 2 callback, and the whole of what keeps it honest: it takes
# back what was kept in the session when they were sent (once, so the same callback can't be played again) and refuses a `state` that isn't the one that
# was sent, or a sign-in that was started for another budget, before it asks Splitwise for anything. It keeps nothing on a refusal, and nothing when the
# person declines. Then ConnectSplitwise swaps the code for a token and makes the connection and its Account, or reconnects the connection that's there.
class SplitwiseCallbacksController < ApplicationController
  def show
    intent = session.delete(SplitwiseSignIn::SESSION_KEY)
    return refuse(since: "its sign-in wasn't the one that was started", to: accounts_path) unless sent_by_us?(intent)

    # The Account being reconnected, when that's what was asked for. A failure goes back to where the person started: its page, or the form.
    account = Current.budget.accounts.find_by(id: intent["account_id"]) if intent["account_id"]
    return refuse(since: "the Account to reconnect has gone", to: accounts_path) if intent["account_id"] && account.nil?

    back = account ? account_path(account) : new_splitwise_connection_path
    return refuse(since: "the sign-in was declined", account: account, to: back, try_again: false) if params[:error].present?
    return refuse(since: "Splitwise sent no code", account: account, to: back) unless params[:code].is_a?(String) && params[:code].present?

    result = ConnectSplitwise.call(budget: Current.budget, code: params[:code], redirect_uri: splitwise_callback_url, account: account,
      name: intent["name"], read_from: intent["read_from"])

    if result.success?
      redirect_to account_path(result.account), notice: "#{result.reconnected ? "Reconnected" : "Connected"} Splitwise as #{result.connection.login_name}"
    else
      refuse(message: result.failure, account: account, to: back)
    end
  end

  private
    # Whether what the session kept is what was sent to Splitwise: the state is the one that came back, and the sign-in was started for this budget.
    def sent_by_us?(intent)
      intent.is_a?(Hash) && params[:state].is_a?(String) && params[:state].present? && intent["budget_id"] == Current.budget.id &&
        ActiveSupport::SecurityUtils.secure_compare(intent["state"].to_s, params[:state])
    end

    # Says why nothing was done, in words, as `since` ("since the sign-in was declined") or as `message` (what Splitwise or the model said). A reconnect
    # changes nothing and a connect keeps nothing. None of it is anything Splitwise answered with, a code or a token.
    def refuse(to:, account: nil, since: nil, message: nil, try_again: true)
      wasnt = "Splitwise wasn't #{account ? "reconnected" : "connected"}"
      reason = since ? "#{wasnt}, since #{since}." : "#{wasnt}. #{message}"
      outcome = account ? "Nothing was changed." : "Nothing was kept."

      redirect_to to, alert: [ reason, outcome, ("Try again." if try_again) ].compact.join(" ")
    end
end
