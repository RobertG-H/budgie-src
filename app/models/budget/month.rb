# One calendar month of a budget, and every balance in it. A plain Ruby object, not a table: nothing is stored,
# and no table has a balance column. A Month only remembers the figures it has worked out for as long as it
# lives, which is one request, so a page can read a figure as often as it likes without asking the database
# again. Every figure on every page comes from here, so the formulas live in one place and views and
# controllers do no arithmetic on balances.
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
  # that PostgreSQL has no dates for. A year has four to six digits, because a date field accepts up to 275760
  # and a Deposit can be dated in any year it does, so each of them has a month to be found in.
  def self.from_param(budget, param)
    year, month = param.to_s.match(/\A(\d{4,6})-(\d{2})\z/)&.captures&.map(&:to_i)
    new(budget, Date.new(year, month, 1)) if year&.positive? && Date.valid_date?(year, month, 1)
  end

  def initialize(budget, date)
    @budget = budget
    @date = date.to_date.beginning_of_month
  end

  def name
    date.to_fs(:month_and_year)
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
      budget.deposits.where(month: ..date).pick(sum_where("month < ?"), sum_where("month = ?"))
    end

    # One column of a query: the total amount where `condition` holds, given this month. Only for the literal
    # conditions above, never for anything a person typed.
    def sum_where(condition)
      Arel.sql(Budget::Deposit.sanitize_sql_array([ "COALESCE(SUM(amount) FILTER (WHERE #{condition}), 0)", date ]))
    end
end
