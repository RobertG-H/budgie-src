# Works out a Budget's Guesses: for an unfiled bank transaction that no active Filing rule fits, what it was most like, so that the
# filing form can start on it and the Unfiled list can show it (ADR 0013). It's the one seam for it: where a Guess comes from is
# behind `sources`, which for now is only the Budget's own filing history (Budget::Guesser::History), and a later source, such as an LLM
# call or a bank-sync provider's category, is another entry there, as its own piece of work with its own ADR.
#
#   guesser = Budget::Guesser.new(budget)
#   guesser.guess(bank_transaction)     # => a Budget::Guess, or nil
#   guesser.guesses(bank_transactions)  # => { bank_transaction.id => Budget::Guess }, only for those that have one
#
# It's for bank transactions that are unfiled, and read back from the database, which works out their normalised description. A Filing rule
# beats a Guess: a bank transaction that an active rule fits has none, since the rule files it, and a rule for an archived envelope is
# inactive, so a Guess can still show for what it would fit. Nothing is stored or created, so there's nothing to go stale when a record is
# edited or a rule changes, and it makes the same number of queries however many bank transactions it's asked about and however many the
# Budget has filed.
class Budget::Guesser
  def initialize(budget)
    @budget = budget
  end

  def guess(bank_transaction)
    guesses([ bank_transaction ])[bank_transaction.id]
  end

  def guesses(bank_transactions)
    return {} if bank_transactions.empty?

    # The rules are loaded once, for all of them.
    matcher = Budget::FilingRule::Matcher.new(@budget.filing_rules.active)
    open = bank_transactions.reject { |bank_transaction| matcher.rule_for(bank_transaction) }
    return {} if open.empty?

    sources.each_with_object({}) do |source, guesses|
      asked = open.reject { |bank_transaction| guesses.key?(bank_transaction.id) }
      guesses.merge!(source.guesses(asked)) if asked.any?
    end
  end

  private
    # In the order they're asked: the first to have a Guess for a bank transaction is the one it gets.
    def sources
      [ Budget::Guesser::History.new(@budget) ]
    end
end
