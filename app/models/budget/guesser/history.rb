# The Budget's own filing history as the source of a Guess (ADR 0013): an unfiled bank transaction is most like the filed ones whose
# description is most like its own, and it's proposed the kind and envelope they were filed as. Nothing leaves the server, it's
# deterministic, and it can say which bank transaction it was like.
#
# What counts as history: Filed bank transactions of the same sign (money in or money out) from any of the Budget's Accounts, as they
# are now: the record's current kind and envelope, so editing one changes the next Guess. Ignored ones don't count, since a Guess never
# proposes Ignore. A bank transaction that was split doesn't either, since its records are in different envelopes, so only those filed as
# exactly one record are history. Neither does anything filed into an archived envelope, which is never proposed. Money in and money out are
# kept apart all the way: a word is only weighed by the history of the same sign (see below).
#
# How alike two descriptions are: A description is read as its words: letters and numbers, as the database normalises them, leaving out
# anything with a digit in it, such as a store number or a reference code, and one-letter words. A description of nothing but numbers is
# read as those numbers instead. The likeness is the words they share over all the words of both, which is 1 for the same words and 0 for
# none, except that a word counts for less the more different outcomes (a kind and an envelope) it's been filed as: "payment" in front of
# every merchant says little, while "rogers" says a lot. A word that's never been filed counts in full. Below a likeness of one half
# there's no Guess, so a merchant the Budget has never filed gets none.
#
# Which outcome: The outcome of the bank transactions that are most alike. When several outcomes are equally alike, the one that was
# filed most often wins, then the one filed most recently, so it's never a toss-up.
#
# Everything comes from one query, which counts the history by description and outcome in the database, so it makes the same number of
# queries however many bank transactions the Budget has filed, and the likenesses are worked out here in Ruby with exact fractions.
class Budget::Guesser::History
  # The least that's alike enough, as the share of the words.
  THRESHOLD = Rational(1, 2)

  # What was filed in one way for one description: how many times, and the latest of them, which is who it's said to be like.
  Group = Data.define(:money_in, :kind, :envelope_id, :envelope_name, :filings, :latest_date, :latest_id, :latest_description, :words) do
    def outcome
      [ kind, envelope_id ]
    end

    def latest
      [ latest_date, latest_id ]
    end
  end

  # The words of a normalised description, as a set. See the top for which count.
  def self.words(normalized_description)
    tokens = normalized_description.to_s.scan(/[\p{L}\p{M}\p{N}]+/)
    words = tokens.reject { |token| token.match?(/\p{N}/) || token.length < 2 }

    (words.presence || tokens).to_set
  end

  def initialize(budget)
    @budget = budget
  end

  # A Guess for each of the bank transactions that has one, by its id.
  def guesses(bank_transactions)
    return {} if bank_transactions.empty?

    groups = load_groups
    return {} if groups.empty?

    lookups = groups.group_by(&:money_in).transform_values { |same_sign| Lookup.new(same_sign) }
    bank_transactions.each_with_object({}) do |bank_transaction, guesses|
      guess = lookups[bank_transaction.amount.positive?]&.guess_for(self.class.words(bank_transaction.normalized_description))
      guesses[bank_transaction.id] = guess if guess
    end
  end

  # The history of one sign, indexed by word so that a bank transaction is only compared with those it shares a word with, and the weight
  # of each word, which is worked out from this history alone, so money in never changes how much a word counts for money out.
  class Lookup
    def initialize(groups)
      @by_word = Hash.new { |hash, word| hash[word] = [] }
      @outcomes_by_word = Hash.new { |hash, word| hash[word] = Set.new }

      groups.each do |group|
        group.words.each do |word|
          @by_word[word] << group
          @outcomes_by_word[word] << group.outcome
        end
      end
    end

    # The Guess for a description with these words, or nothing when no history is alike enough.
    def guess_for(words)
      scored = candidates(words).map { |group| [ group, likeness(words, group.words) ] }.select { |_, score| score >= THRESHOLD }
      return if scored.empty?

      best = scored.map(&:last).max
      guess_from(scored.select { |_, score| score == best }.map(&:first))
    end

    private
      def candidates(words)
        words.flat_map { |word| @by_word.key?(word) ? @by_word[word] : [] }.uniq
      end

      # The weight of the words they share over the weight of all their words, as an exact fraction.
      def likeness(words, other_words)
        shared = words & other_words
        return Rational(0) if shared.empty?

        total(shared) / total(words | other_words)
      end

      def total(words)
        words.sum(Rational(0)) { |word| weight(word) }
      end

      # A word that's in one outcome's history counts in full, and one that's in several counts for a share of that.
      def weight(word)
        @outcomes_by_word.key?(word) ? Rational(1, @outcomes_by_word[word].size) : Rational(1)
      end

      # The outcome that was filed most often, then most recently, and the bank transaction of that outcome that it's said to be like.
      def guess_from(groups)
        _, same_outcome = groups.group_by(&:outcome).max_by { |_, outcome_groups| [ outcome_groups.sum(&:filings), outcome_groups.map(&:latest).max ] }
        latest = same_outcome.max_by(&:latest)

        Budget::Guess.new(kind: latest.kind, envelope_id: latest.envelope_id, envelope_name: latest.envelope_name, like: latest.latest_description)
      end
  end

  private
    # What the Budget filed, counted by description and outcome, in one query. Each bank transaction's links are counted first, over all of
    # three link tables, so that one filed as more than one record is left out whatever its records are in, and an archived envelope is only
    # left out afterwards, so that a split with one record in one doesn't look like a single record. The three kinds come from
    # BankTransaction.links_by_record, as everything that treats them alike does. A Deposit has no envelope.
    def load_groups
      rows = Budget::BankTransaction.connection.select_all(Budget::BankTransaction.sanitize_sql_array([ history_sql, { budget_id: @budget.id } ]), "Guess history").cast_values

      rows.map do |money_in, kind, envelope_id, envelope_name, normalized_description, filings, latest_date, latest_id, latest_description|
        Group.new(money_in: money_in, kind: kind, envelope_id: envelope_id, envelope_name: envelope_name, filings: filings, latest_date: latest_date,
          latest_id: latest_id, latest_description: latest_description, words: self.class.words(normalized_description))
      end
    end

    def history_sql
      <<~SQL.squish
        WITH mine AS (
          SELECT bank_transactions.id, bank_transactions.date, bank_transactions.description, bank_transactions.normalized_description,
                 bank_transactions.amount > 0 AS money_in
          FROM budget_bank_transactions bank_transactions
          JOIN budget_accounts accounts ON accounts.id = bank_transactions.account_id
          WHERE accounts.budget_id = :budget_id AND bank_transactions.ignored_at IS NULL
        ), records AS (
          #{link_selects.join(" UNION ALL ")}
        )
        SELECT mine.money_in, records.kind, records.envelope_id, envelopes.name, mine.normalized_description, COUNT(*),
               MAX(mine.date),
               (ARRAY_AGG(mine.id ORDER BY mine.date DESC, mine.id DESC))[1],
               (ARRAY_AGG(mine.description ORDER BY mine.date DESC, mine.id DESC))[1]
        FROM records
        JOIN mine ON mine.id = records.bank_transaction_id
        LEFT JOIN budget_envelopes envelopes ON envelopes.id = records.envelope_id
        WHERE records.bank_transaction_id IN (SELECT bank_transaction_id FROM records GROUP BY bank_transaction_id HAVING COUNT(*) = 1)
          AND envelopes.archived_at IS NULL
        GROUP BY mine.money_in, records.kind, records.envelope_id, envelopes.name, mine.normalized_description
      SQL
    end

    # One SELECT for each kind of record: which bank transaction it was filed from, what kind it is and its envelope, among the
    # Budget's own bank transactions.
    def link_selects
      Budget::BankTransaction.links_by_record.map do |record_class, link_class|
        record_table = record_class.table_name
        link_table = link_class.table_name
        envelope_id = record_class.column_names.include?("envelope_id") ? "#{record_table}.envelope_id" : "CAST(NULL AS bigint)"

        "SELECT #{link_table}.bank_transaction_id, '#{record_class.model_name.element}' AS kind, #{envelope_id} AS envelope_id " \
          "FROM #{link_table} JOIN #{record_table} ON #{record_table}.id = #{link_table}.#{record_class.model_name.element}_id " \
          "WHERE #{link_table}.bank_transaction_id IN (SELECT id FROM mine)"
      end
    end
end
