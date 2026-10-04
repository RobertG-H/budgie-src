# Filing a page of the unfiled bank transactions' Guesses in one click, after a review list (ADR 0012): "File N as guessed". A Guess only
# ever suggests, so nothing is filed until this is asked for, and then only the rows that were reviewed and left ticked, each as it was
# reviewed. It reviews one page of one Account's unfiled bank transactions, or of every Account's when none is chosen (`filter[account]`),
# and goes back to the Unfiled state of the Bank transactions page for the same Account.
#
# It files through the same operation a person uses (Budget::Filing), all or none, so what filing by hand would refuse it refuses, such
# as an envelope archived since the review, or a bank transaction filed since. It makes no Filing rule, and what it files has none noted,
# because a Guess isn't a rule: only a person asking for "Always file like this" makes one. Another user's bank transaction is a 404.
class GuessedFilingsController < ApplicationController
  include BankTransactionsPage

  helper_method :unfiled_path

  # The review: the rows of the page that have a Guess, each ticked, with the Guess it would be filed as.
  def new
    load_bank_transactions_page(unfiled_list)
    @reviewed = @bank_transactions.select { |bank_transaction| @guesses.key?(bank_transaction.id) }
  end

  # Files the ticked rows as they were reviewed, which is what the review sent for each, and not what its Guess is now, so that nothing is
  # filed that wasn't seen. It goes back to the page the review was for, or to the review when it's refused, so what's left can be seen.
  def create
    reviewed = reviewed_outcomes
    return redirect_to(review_path, alert: "Choose at least one bank transaction to file.") if reviewed.empty?

    entries = Current.budget.bank_transactions.find(reviewed.keys).map do |bank_transaction|
      Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: [ Budget::Filing::Draft.for(bank_transaction, **Budget::Guess.draft_attributes_from(reviewed[bank_transaction.id.to_s])) ])
    end

    if Budget::Filing.new(Current.budget).file(entries)
      redirect_to unfiled_path, notice: "#{helpers.pluralize(entries.size, "bank transaction")} filed as guessed."
    else
      redirect_to review_path, alert: refusal(entries)
    end
  end

  private
    # The unfiled bank transactions the review is about: the Account's that was chosen, if one was, and never another budget's.
    def unfiled_list
      @unfiled_list ||= Budget::BankTransactionList.parse(Current.budget, params[:filter]).unfiled
    end

    # The Account chosen, as the params that say so, which the review and where it goes back to carry.
    def account_params
      unfiled_list.account_params
    end

    # The review of the page, which is where a refusal goes back to.
    def review_path
      new_guessed_filing_path(filter: account_params, page: page_param)
    end

    # The Unfiled state of the Bank transactions page, for the same Account and at the page the review was for.
    def unfiled_path
      bank_transactions_path(filter: account_params.merge(state: "unfiled"), page: page_param)
    end

    # What the review sent for each row that was ticked, by its id: only ticked checkboxes are sent. Only that one key of the form is looked
    # at, so the page it was opened from isn't reported as unpermitted.
    def reviewed_outcomes
      params.slice(:guessed).permit(guessed: {})[:guessed].to_h
    end

    # Why nothing was filed, for the first row that was refused, in the words filing by hand uses.
    def refusal(entries)
      entry = entries.find(&:refused?)

      "Nothing was filed. #{entry.bank_transaction.description}: #{entry.full_messages.map { |message| message.end_with?(".") ? message : "#{message}." }.join(" ")}"
    end
end
