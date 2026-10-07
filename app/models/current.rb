class Current < ActiveSupport::CurrentAttributes
  # The header says "99+ unfiled" for this many unfiled bank transactions and more, and the same for how many are to review, so counting never goes
  # further than one past it.
  UNFILED_COUNT_CAP = 99

  attribute :session, :bank_transaction_counts
  delegate :user, to: :session, allow_nil: true

  # The one way controllers and views find the budget. For now it's the signed-in user's, if they have one.
  def budget
    user&.budget
  end

  # How many of the budget's bank transactions are unfiled, up to one past UNFILED_COUNT_CAP, for the header's link to them.
  def unfiled_count
    bank_transaction_counts.first
  end

  # How many are to review, which is what a Filing rule filed or ignored that nobody has looked at (ADR 0017), up to one past the same cap.
  def to_review_count
    bank_transaction_counts.last
  end

  private
    # Both counts, in one query, since every page that has the header asks, and the header costs one however many there are: each is counted with a limit
    # so a lot of them doesn't make it dear, and they're counted once per request. Only for a signed-in person with a budget.
    def bank_transaction_counts
      super || (self.bank_transaction_counts = count_bank_transactions)
    end

    def count_bank_transactions
      limited = lambda do |relation|
        rows = relation.select(Arel.sql("1")).limit(UNFILED_COUNT_CAP + 1).arel.as("counted")
        Arel::Nodes::Grouping.new(Arel::SelectManager.new.from(rows).project(Arel.star.count).ast)
      end
      bank_transactions = budget.bank_transactions

      Budget::BankTransaction.connection.select_rows(Arel::SelectManager.new.project(limited.call(bank_transactions.unfiled), limited.call(bank_transactions.to_review))).first.map(&:to_i)
    end
end
