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
# after it, since none of them is stored. That can leave a later month's Ready to Assign negative. Changing a Spend, a
# Refund or a Reallocation does the same to Carried over and Available. A Spend, a Refund or a Reallocation between
# envelopes never changes Ready to Assign: money spent was already assigned, money that comes back lands in its envelope
# and money moved between envelopes nets to zero. A Reallocation to Ready to Assign does, from the month of its date.
class Budget::Month
  ZERO = BigDecimal(0)

  # There's no month before January of year 1: PostgreSQL has no year 0, so /months/0000-12 is a 404. Nothing is bounded after.
  EARLIEST = Date.new(1, 1, 1)

  # Money not yet assigned to an envelope: every Deposit for this month and the months before it, less everything
  # assigned in them, plus everything moved back into it from envelopes. `carried_over` is what was left at the end of
  # last month, `deposited` is what came in this month, `assigned` is what went to envelopes this month, all of them, and
  # `reallocated` is what came back from envelopes this month, all of them.
  #
  # The card on the month view says in words which of four states it's in, and these say which so the view does no arithmetic. A
  # month is in exactly one of them: they all turn on the amount, so they can't overlap, and nothing is "empty" or "all assigned"
  # while it's over-assigned.
  ReadyToAssign = Data.define(:amount, :carried_over, :deposited, :assigned, :reallocated) do
    # Over-assigned: more has been assigned than there is to assign, so Ready to Assign is below zero.
    def over_assigned?
      amount.negative?
    end

    # There is money left to assign.
    def to_assign?
      amount.positive?
    end

    # Nothing has happened yet: no Carried over, Deposited, Assigned or Reallocated, such as a new budget's first month.
    def empty?
      amount.zero? && [ carried_over, deposited, assigned, reallocated ].all?(&:zero?)
    end

    # Everything that came in has been assigned: nothing is left, and there is something that came in or went out to show for it.
    def all_assigned?
      amount.zero? && !empty?
    end

    # Which of the four states this is, in the order they win: :over_assigned, :empty, :all_assigned or :to_assign.
    def state
      return :over_assigned if over_assigned?
      return :empty if empty?

      all_assigned? ? :all_assigned : :to_assign
    end
  end

  # What's been assigned to, spent from, refunded to or reallocated to one envelope in the months before this one, and in
  # this one.
  Totals = Data.define(:before, :in_month)
  NOTHING = Totals.new(before: ZERO, in_month: ZERO)

  # One envelope's figures for this month: what it carries over (its Starting balance and everything assigned to it
  # in the months before, less everything spent from it and plus everything refunded to it and moved into it from other
  # envelopes, less what's moved out of it, to another envelope or to Ready to Assign), what's assigned to it, spent from
  # it and refunded to it this month, what was moved into it less what was moved out of it (Reallocated, which is
  # negative when more left than arrived), and what's left, which is what's Available.
  EnvelopeLine = Data.define(:envelope, :carried_over, :assigned, :spent, :refunded, :reallocated, :available) do
    # Overspent: the envelope's Available is below zero.
    def overspent?
      available.negative?
    end

    # How much of what the envelope had to spend is left, below which it's "a little" and not "plenty". Exactly this is plenty.
    A_LITTLE = Rational(1, 4)

    # What the envelope had to spend this month: Carried over, Assigned, Refunded and Reallocated added up, counting only
    # the positive part of Carried over (an Overspent envelope carries a negative one) and of Reallocated (the net of money in
    # and out), so Available is never more than this and its share of it is never over 100%.
    def had_to_spend
      [ carried_over, ZERO ].max + assigned + refunded + [ reallocated, ZERO ].max
    end

    # How Available the envelope is, from this line's own figures, for the bar under Available: :overspent (below zero, even
    # when it had nothing to spend), :none (nothing to spend, no Spends: no bar), :little (under a quarter of what it had to
    # spend, so everything spent is a little) or :plenty.
    def available_level
      return :overspent if overspent?
      return :none if had_to_spend.zero? && spent.zero?

      available_share < A_LITTLE ? :little : :plenty
    end

    # Available as a share of what the envelope had to spend, exactly, between 0 and 1: 0 when it had nothing to spend.
    def available_share
      return Rational(0) if had_to_spend.zero?

      Rational(available.clamp(ZERO, had_to_spend), had_to_spend)
    end

    # The bar's length in whole percent, 0 to 100: the share rounded down, so a bar reads 25 or more only when the level is plenty
    # and 100 only when nothing is spent, however tiny the share, a full bar when Overspent, and nil when there's no bar.
    def available_percent
      case available_level
      when :none then nil
      when :overspent then 100
      else (available_share * 100).floor
      end
    end

    # Whether every figure on the line is zero. Available is the sum of the others, so it is too.
    def empty?
      [ carried_over, assigned, spent, refunded, reallocated ].all?(&:zero?)
    end

    # An archived envelope's line is only shown in a month where it has figures, which is hiding by figures and not by
    # date: nothing can hide in an archived envelope. An envelope in use always shows.
    def shown?
      !envelope.archived? || !empty?
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

  def earliest?
    date == EARLIEST
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
      reallocated_before = ready_to_assign_reallocation_totals.values.sum(ZERO, &:before)
      reallocated = ready_to_assign_reallocation_totals.values.sum(ZERO, &:in_month)
      carried_over = deposited_before - assigned_before + reallocated_before

      ReadyToAssign.new(
        amount: carried_over + deposited - assigned + reallocated, carried_over: carried_over, deposited: deposited,
        assigned: assigned, reallocated: reallocated
      )
    end
  end

  # The lines to show for the month, alphabetically: every envelope in use, and the archived ones that have a figure in
  # this month. Every envelope's figures are worked out whether it's shown or not, so the number of queries is the same.
  def envelopes
    @envelopes ||= all_envelope_lines.select(&:shown?)
  end

  # The budget's archived envelopes, alphabetically, whether the month shows them or not.
  def archived_envelopes
    @archived_envelopes ||= all_envelope_lines.map(&:envelope).select(&:archived?)
  end

  # One envelope's line, found by its id like any other record of the budget, archived or not, shown or not: another
  # budget's envelope, or one that doesn't exist, is ActiveRecord::RecordNotFound.
  def envelope_line(id)
    all_envelope_lines.find { |line| line.envelope.id == id.to_i } or raise ActiveRecord::RecordNotFound
  end

  private
    # Every envelope of the budget, alphabetically.
    def all_envelope_lines
      @all_envelope_lines ||= budget.envelopes.alphabetical.map do |envelope|
        assigned = assignment_totals.fetch(envelope.id, NOTHING)
        spent = spend_totals.fetch(envelope.id, NOTHING)
        refunded = refund_totals.fetch(envelope.id, NOTHING)
        reallocated = reallocation_totals.fetch(envelope.id, NOTHING)
        carried_over = envelope.starting_balance + assigned.before - spent.before + refunded.before + reallocated.before

        EnvelopeLine.new(
          envelope: envelope, carried_over: carried_over, assigned: assigned.in_month, spent: spent.in_month,
          refunded: refunded.in_month, reallocated: reallocated.in_month,
          available: carried_over + assigned.in_month - spent.in_month + refunded.in_month + reallocated.in_month
        )
      end
    end

    # Deposits for the months before this one, and for this one, from a single query.
    def deposit_totals
      budget.deposits.where(month: ..date).pick(sum_where("month < ?"), sum_where("month = ?"))
    end

    # What's assigned to each envelope, from a single query: { envelope id => Totals }. An envelope with
    # nothing assigned up to this month isn't in it. The budget's own totals are added up from these, so they always
    # agree with its envelopes'.
    def assignment_totals
      @assignment_totals ||= budget.assignments.where(month: ..date).group(:envelope_id)
        .pluck(:envelope_id, sum_where("month < ?"), sum_where("month = ?"))
        .to_h { |envelope_id, before, in_month| [ envelope_id, Totals.new(before: before, in_month: in_month) ] }
    end

    # What's spent from each envelope, from a single query: { envelope id => Totals }. An envelope with nothing spent
    # up to the end of this month isn't in it.
    def spend_totals
      @spend_totals ||= dated_totals(budget.spends)
    end

    # What's refunded to each envelope, from a single query: { envelope id => Totals }, in the same way.
    def refund_totals
      @refund_totals ||= dated_totals(budget.refunds)
    end

    # What's moved into each envelope less what's moved out of it, to another envelope or to Ready to Assign, from three
    # queries: { envelope id => Totals }. An envelope with nothing moved either way up to the end of this month isn't in
    # it. The first two go through the budget's From envelopes, and a Reallocation's To envelope is always in the same
    # budget.
    def reallocation_totals
      @reallocation_totals ||= begin
        moved_in = dated_totals(budget.envelope_reallocations, by: :to_envelope_id)
        moved_out = dated_totals(budget.envelope_reallocations, by: :from_envelope_id)
        moved_to_ready_to_assign = ready_to_assign_reallocation_totals

        (moved_in.keys | moved_out.keys | moved_to_ready_to_assign.keys).to_h do |envelope_id|
          into = moved_in.fetch(envelope_id, NOTHING)
          out_of = moved_out.fetch(envelope_id, NOTHING)
          to_ready_to_assign = moved_to_ready_to_assign.fetch(envelope_id, NOTHING)
          [ envelope_id, Totals.new(
            before: into.before - out_of.before - to_ready_to_assign.before,
            in_month: into.in_month - out_of.in_month - to_ready_to_assign.in_month
          ) ]
        end
      end
    end

    # What's moved out of each envelope back into Ready to Assign, from a single query: { envelope id => Totals }. The
    # budget's own total is added up from these, as Assigned is, so it always agrees with its envelopes'.
    def ready_to_assign_reallocation_totals
      @ready_to_assign_reallocation_totals ||= dated_totals(budget.ready_to_assign_reallocations)
    end

    # Each envelope's totals from dated records, as { envelope id => Totals }, grouped by the column that names the
    # envelope. A Spend, a Refund or a Reallocation counts in the month its date is in, and in every month after it.
    def dated_totals(records, by: :envelope_id)
      records.where(date: ..date.end_of_month).group(by)
        .pluck(by, sum_where("date < ?"), sum_where("date >= ?"))
        .to_h { |envelope_id, before, in_month| [ envelope_id, Totals.new(before: before, in_month: in_month) ] }
    end

    # One column of a query: the total amount where `condition` holds, given this month. Only for the literal
    # conditions above, never for anything a person typed.
    def sum_where(condition)
      Arel.sql(ApplicationRecord.sanitize_sql_array([ "COALESCE(SUM(amount) FILTER (WHERE #{condition}), 0)", date ]))
    end
end
