# What the controllers that act on one bank transaction have in common: they find it through the user's budget, by way of its
# Account, so another user's is a 404, and they go back to the page the form was opened from, which is the Bank transactions page or the
# Account's page (ReturnsToOrigin), or the Account's page when it isn't known.
#
# "And next" is working through the unfiled bank transactions of the list a form was opened from without going back to it after each one: the
# next is the first unfiled one older than this one in that list's order, and when none is older the newest one left (Budget::BankTransaction#next_unfiled).
# The list is the Bank transactions page's, in the Account it was filtered to if it was, or the Account's page's, in that Account. A form that wasn't
# opened from either has no list, so no next.
module BankTransactionScoped
  extend ActiveSupport::Concern

  included do
    include ReturnsToOrigin

    before_action :set_bank_transaction
    helper_method :origin_path, :next_unfiled
  end

  private
    def set_bank_transaction
      @bank_transaction = Current.budget.bank_transactions.find(params[:bank_transaction_id])
    end

    def origin_path
      return_path(account: @bank_transaction.account)
    end

    # The next unfiled bank transaction in the list the form was opened from: nothing when there's none to go on to, or no list. It's one query, and is
    # only run when it's asked for, which is when the buttons are drawn or "and next" was pressed, and after what the form did has been done, so the
    # bank transaction just filed or ignored is never offered.
    def next_unfiled
      return @next_unfiled if defined?(@next_unfiled)

      scope = next_scope
      @next_unfiled = scope && @bank_transaction.next_unfiled(scope: scope)
    end

    # The bank transactions "and next" goes through, found through the budget so another user's are never reached: every Account's, or the one the
    # Bank transactions page was filtered to, or the Account's own for its page. The state and the dates don't matter to the unfiled ones.
    def next_scope
      case origin
      when "bank_transactions"
        account = Budget::BankTransactionList.parse(Current.budget, params[:filter]).account
        account ? Current.budget.bank_transactions.where(account_id: account.id) : Current.budget.bank_transactions
      when "account" then @bank_transaction.account.bank_transactions
      end
    end

    # Where it goes once a bank transaction has been filed or ignored: back to where the form was opened from, or when "and next" was pressed, on to
    # the form of the next one, with the same way back (`from`, `filter` and `page`) so that Cancel, File and the next "and next" behave the same, or
    # back to where it was opened from, saying so, when none is left.
    def redirect_after_filing(notice)
      return redirect_to(origin_path, notice: notice) unless params[:next] == "1" && next_scope

      if next_unfiled
        redirect_to new_bank_transaction_filing_path(next_unfiled, origin_params(nil)), notice: notice
      else
        redirect_to origin_path, notice: "#{notice} No more unfiled bank transactions."
      end
    end
end
