# A page of the Unfiled list, which is what its list and the review for filing its Guesses are both about: the budget's unfiled bank
# transactions, newest first, 50 a page, with the Guess of each that has one. Everything is loaded up front, so the page runs the same
# number of queries however many rows it has, however many rules the Budget has and however much it has filed.
module UnfiledPage
  extend ActiveSupport::Concern
  include Paginated

  included do
    helper_method :page_param, :unfiled_page_path
  end

  private
    # `@bank_transactions` is the page asked for (see Paginated), each with its Account and its links loaded, none of them having any, so
    # that saying what state it's in takes no query of its own, and `@guesses` is the Guess of each that has one, by its id.
    def load_unfiled_page
      @bank_transactions = paginate(Current.budget.bank_transactions.unfiled.includes(:account, :deposit_links, :spend_links, :refund_links).newest_first)
      @guesses = Budget::Guesser.new(Current.budget).guesses(@bank_transactions)
    end

    # The page number to put in an address, which is none for the first.
    def page_param
      page unless page == 1
    end

    # Where the Unfiled list is, at the page this one is for.
    def unfiled_page_path
      unfiled_bank_transactions_path(page: page_param)
    end
end
