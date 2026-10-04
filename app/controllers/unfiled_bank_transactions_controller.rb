# Every bank transaction in the budget that hasn't been filed or ignored, across its Accounts, newest first, a page at a time. It's
# where a person works through what's left, and where Guesses will be shown.
class UnfiledBankTransactionsController < ApplicationController
  include Paginated

  helper_method :more_pages?

  # Each one's links are loaded with it, none of them having any, so that saying what state it's in takes no query of its own.
  def index
    @bank_transactions = paginate(Current.budget.bank_transactions.unfiled.includes(:account, :deposit_links, :spend_links, :refund_links).newest_first)
  end
end
