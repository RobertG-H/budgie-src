# One calendar month of a budget, and every balance in it. A plain Ruby object, not a table: nothing here is
# stored or cached, and no table has a balance column. Every figure on every page comes from here, so the
# formulas live in one place and views and controllers do no arithmetic on balances.
#
# It works on the calendar month containing the date it's given, and runs a fixed number of grouped SUM queries,
# each split into "before the month" and "in the month", so the number of queries doesn't grow with the months
# of history or with the number of envelopes. Amounts are BigDecimal throughout.
class Budget::Month
  # Money not yet assigned to an envelope: every Deposit for this month and the months before it.
  ReadyToAssign = Data.define(:amount, :carried_over, :deposited)

  # One envelope's figures for this month.
  EnvelopeLine = Data.define(:envelope, :carried_over, :available) do
    # Overspent: the envelope's Available is below zero.
    def overspent?
      available.negative?
    end
  end

  attr_reader :budget, :date

  # The month a URL names by its year and month, such as "2026-09". Anything else is nil, and so is a year
  # that PostgreSQL has no dates for.
  def self.from_param(budget, param)
    year, month = param.to_s.match(/\A(\d{4})-(\d{2})\z/)&.captures&.map(&:to_i)
    new(budget, Date.new(year, month, 1)) if year&.positive? && Date.valid_date?(year, month, 1)
  end

  def initialize(budget, date)
    @budget = budget
    @date = date.to_date.beginning_of_month
  end

  def name
    date.strftime("%B %Y")
  end

  def to_param
    date.strftime("%Y-%m")
  end

  def previous
    self.class.new(budget, date.prev_month)
  end

  def next
    self.class.new(budget, date.next_month)
  end

  # Today's month, by the app's time zone.
  def current
    self.class.new(budget, Date.current)
  end

  def current?
    date == current.date
  end

  def ready_to_assign
    @ready_to_assign ||= begin
      carried_over, deposited = deposit_totals
      ReadyToAssign.new(amount: carried_over + deposited, carried_over: carried_over, deposited: deposited)
    end
  end

  # The budget's envelopes, alphabetically. Nothing moves money in or out of an envelope yet, so each one's
  # Available is its Starting balance in every month, and what it carries over is the same.
  def envelopes
    @envelopes ||= budget.envelopes.alphabetical.map do |envelope|
      EnvelopeLine.new(envelope: envelope, carried_over: envelope.starting_balance, available: envelope.starting_balance)
    end
  end

  private
    # Deposits for the months before this one, and for this one, from a single query.
    def deposit_totals
      before_this_month = Arel.sql(Budget::Deposit.sanitize_sql_array([ "COALESCE(SUM(amount) FILTER (WHERE month < ?), 0)", date ]))
      in_this_month = Arel.sql(Budget::Deposit.sanitize_sql_array([ "COALESCE(SUM(amount) FILTER (WHERE month = ?), 0)", date ]))

      budget.deposits.where(month: ..date).pick(before_this_month, in_this_month)
    end
end
