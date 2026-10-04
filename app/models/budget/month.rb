# One calendar month of a budget, and every balance in it. A plain Ruby object, not a table: nothing is stored,
# and no table has a balance column. A Month only remembers the figures it has worked out for as long as it
# lives, which is one request, so a page can read a figure as often as it likes without asking the database
# again. Every figure on every page comes from here, so the formulas live in one place and views and
# controllers do no arithmetic on balances.
#
# It works on the calendar month containing the date it's given, and runs a fixed number of grouped SUM queries,
# each split into "before the month" and "in the month", so the number of queries doesn't grow with the months
# of history or with the number of envelopes. Amounts are BigDecimal throughout.
#
# Changing what's assigned in an earlier month changes Carried over, Available and Ready to Assign in every month
# after it, since none of them is stored. That can leave a later month's Ready to Assign negative.
class Budget::Month
  ZERO = BigDecimal(0)

  # Money not yet assigned to an envelope: every Deposit for this month and the months before it, less everything
  # assigned in them. `carried_over` is what was left at the end of last month, `deposited` is what came in this
  # month and `assigned` is what went to envelopes this month, all of them.
  ReadyToAssign = Data.define(:amount, :carried_over, :deposited, :assigned) do
    # Over-assigned: more has been assigned than there is to assign, so Ready to Assign is below zero.
    def over_assigned?
      amount.negative?
    end
  end

  # What's assigned to one envelope in the months before this one, and in this one.
  AssignedTotals = Data.define(:before, :in_month)
  NOTHING_ASSIGNED = AssignedTotals.new(before: ZERO, in_month: ZERO)

  # One envelope's figures for this month: what it carries over (its Starting balance and everything assigned to it
  # in the months before), what's assigned to it this month, and the two together, which is what's Available.
  EnvelopeLine = Data.define(:envelope, :carried_over, :assigned, :available) do
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
      deposited_before, deposited = deposit_totals
      assigned_before = assignment_totals.values.sum(ZERO, &:before)
      assigned = assignment_totals.values.sum(ZERO, &:in_month)
      carried_over = deposited_before - assigned_before

      ReadyToAssign.new(amount: carried_over + deposited - assigned, carried_over: carried_over, deposited: deposited, assigned: assigned)
    end
  end

  # The budget's envelopes, alphabetically.
  def envelopes
    @envelopes ||= budget.envelopes.alphabetical.map do |envelope|
      totals = assignment_totals.fetch(envelope.id, NOTHING_ASSIGNED)
      carried_over = envelope.starting_balance + totals.before

      EnvelopeLine.new(envelope: envelope, carried_over: carried_over, assigned: totals.in_month, available: carried_over + totals.in_month)
    end
  end

  # One envelope's line, found by its id like any other record of the budget: another budget's envelope, or one that
  # doesn't exist, is ActiveRecord::RecordNotFound.
  def envelope_line(id)
    envelopes.find { |line| line.envelope.id == id.to_i } or raise ActiveRecord::RecordNotFound
  end

  private
    # Deposits for the months before this one, and for this one, from a single query.
    def deposit_totals
      budget.deposits.where(month: ..date).pick(sum_where("month < ?"), sum_where("month = ?"))
    end

    # What's assigned to each envelope, from a single query: { envelope id => AssignedTotals }. An envelope with
    # nothing assigned up to this month isn't in it. The budget's own totals are added up from these, so they always
    # agree with its envelopes'.
    def assignment_totals
      @assignment_totals ||= budget.assignments.where(month: ..date).group(:envelope_id)
        .pluck(:envelope_id, sum_where("month < ?"), sum_where("month = ?"))
        .to_h { |envelope_id, before, in_month| [ envelope_id, AssignedTotals.new(before: before, in_month: in_month) ] }
    end

    # One column of a query: the total amount where `condition` holds, given this month. Only for the literal
    # conditions above, never for anything a person typed.
    def sum_where(condition)
      Arel.sql(ApplicationRecord.sanitize_sql_array([ "COALESCE(SUM(amount) FILTER (WHERE #{condition}), 0)", date ]))
    end
end
