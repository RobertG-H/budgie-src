# Every bank transaction of the budget, from every Account and in any state, newest first, a page at a time: the page where a person works
# through what's unfiled, looks at what's filed or ignored, and does any of it, such as filing, ignoring or un-filing, and comes back to
# the same filtered page (`from=bank_transactions`, see ReturnsToOrigin). The filters are one nested param, `filter`: the state, the Account
# and the dates, which Unfiled and To review take optionally (see Budget::BankTransactionList). Where a Guess is, in the unfiled rows, it's shown,
# and a page of the unfiled ones can be filed as guessed (GuessedFilingsController).
class BankTransactionsController < ApplicationController
  include BankTransactionsPage

  def index
    list = Budget::BankTransactionList.parse(Current.budget, params[:filter])
    flash.now[:alert] = list.date_range.error unless list.date_range.valid?

    load_bank_transactions_page(list)
  end
end
