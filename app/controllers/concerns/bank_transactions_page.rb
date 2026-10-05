# A page of the bank transactions of a Budget::BankTransactionList, which is what the Bank transactions page and the review for filing its
# Guesses are both about: newest first, 50 a page, each with its Account, the records it was filed as and the Filing rule that did it, and
# the Guess of each that's unfiled. Everything is loaded up front, so the page runs the same number of queries however many rows it has,
# whatever states they're in, however many rules the Budget has and however much it has filed.
module BankTransactionsPage
  extend ActiveSupport::Concern
  include Paginated

  included do
    helper_method :page_param
  end

  private
    # What a row needs so that saying what state it's in, and showing what it was filed as and by which Filing rule, takes no query of its
    # own: the union of what the Unfiled list and an Account's page each needed.
    PRELOADS = [ :account, { deposit_links: :deposit, spend_links: { spend: :envelope }, refund_links: { refund: :envelope }, filing_rule: :envelope } ].freeze

    # `@list` is the list, `@bank_transactions` the page asked for (see Paginated) and `@guesses` the Guess of each unfiled one on it that
    # has one, by its id, whichever state the list is in: it costs no query of its own.
    def load_bank_transactions_page(list)
      @list = list
      @bank_transactions = paginate(list.bank_transactions.preload(PRELOADS).newest_first)
      @guesses = Budget::Guesser.new(Current.budget).guesses(@bank_transactions.select(&:unfiled?))
    end

    # The page number to put in an address, which is none for the first.
    def page_param
      page unless page == 1
    end
end
