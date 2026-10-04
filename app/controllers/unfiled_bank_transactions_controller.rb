# Every bank transaction in the budget that hasn't been filed or ignored, across its Accounts, newest first, a page at a time. It's
# where a person works through what's left, and where each one's Guess is shown, if it has one, and a page of them can be filed as
# guessed (GuessedFilingsController).
class UnfiledBankTransactionsController < ApplicationController
  include UnfiledPage

  def index
    load_unfiled_page
  end
end
