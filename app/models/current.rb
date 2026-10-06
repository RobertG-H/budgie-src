class Current < ActiveSupport::CurrentAttributes
  # The header says "99+ unfiled" for this many unfiled bank transactions and more, so counting never goes further than one past it.
  UNFILED_COUNT_CAP = 99

  attribute :session, :unfiled_count
  delegate :user, to: :session, allow_nil: true

  # The one way controllers and views find the budget. For now it's the signed-in user's, if they have one.
  def budget
    user&.budget
  end

  # How many of the budget's bank transactions are unfiled, up to one past UNFILED_COUNT_CAP, for the header's link to them. Every page that has the
  # header asks, so it's counted once per request, with a limit so a lot of them doesn't make it dear. Only for a signed-in person with a budget.
  def unfiled_count
    super || (self.unfiled_count = budget.bank_transactions.unfiled.limit(UNFILED_COUNT_CAP + 1).count)
  end
end
