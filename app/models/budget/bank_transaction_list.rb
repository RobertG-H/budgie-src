# The bank transactions of a budget, of every Account and in any state, for the Bank transactions page. It's made from the params the
# page is given, `filter`, which it reads the way a page does and never trusts: what it doesn't understand is dropped, so `to_params` is
# always something it understood and nothing a person sent (as Budget::RecordList does for the Records page).
#
# - `state` is `all` (the default), `unfiled`, `to_review`, `filed` or `ignored`. To review is what a Filing rule filed or ignored and nobody
#   has looked at yet (ADR 0017).
# - `account` is the id of one of the budget's Accounts; blank, unknown or another budget's is all Accounts.
# - `date_from` and `date_to` are a DateRangeFilter, and apply to a bank transaction's `date`. Unfiled and To review take them optionally: with
#   none, which is how they start, every one of them is listed whatever its date, so one is never lost to a range (#104). In every other state
#   the range is the current month unless it's given, and All lists every unfiled bank transaction whatever its date together with the filed
#   and ignored ones in the range.
# - `from_state` is the state the form that sent the filter was showing, and is only read, never kept: when the state is changed to Unfiled or To
#   review the dates it sent are dropped, so the current month that All or Filed default to doesn't come along (it's not in `to_params`).
#
# Everything is found through the budget's Accounts, so another budget's bank transactions never appear.
class Budget::BankTransactionList
  STATES = %w[ all unfiled to_review filed ignored ].freeze
  # The states whose range is optional, which start with every date.
  OPTIONAL_RANGE_STATES = %w[ unfiled to_review ].freeze

  attr_reader :budget, :date_range, :state, :account

  # `filter` is what the page was given: ActionController::Parameters, a Hash, or anything at all. `state` forces the state, for a page that's about
  # one whatever the filter says, such as the review for "File N as guessed".
  def self.parse(budget, filter, state: nil)
    values = Budget::FilterValues.read(filter)
    state = normalize_state(state || values[:state])
    optional = state.in?(OPTIONAL_RANGE_STATES)
    from_state = normalize_state(values[:from_state], default: nil)
    # Changing to a state that has no range to start with drops the one the other had.
    dates = optional && from_state && from_state != state ? {} : values.slice(:date_from, :date_to)

    new(budget, date_range: DateRangeFilter.new(from: dates[:date_from], to: dates[:date_to], optional: optional), state: state, account_id: values[:account])
  end

  def self.normalize_state(state, default: "all")
    (state.presence_in(STATES) if state.is_a?(String)) || default
  end

  def initialize(budget, date_range:, state: nil, account_id: nil)
    @budget = budget
    @date_range = date_range
    @state = self.class.normalize_state(state)
    @account = accounts.find { |candidate| candidate.id.to_s == account_id } if account_id.is_a?(String) && account_id.match?(/\A\d+\z/)
  end

  # What was understood, as the params that spell it, for a link or a hidden field. A state of All is the default and isn't said, and neither
  # is a range that's any date.
  def to_params
    date_range.to_params.merge(state: (state unless state == "all"), account: account&.id&.to_s).compact
  end

  # The Account and the dates, which is all that "File N as guessed" carries: it reviews and files one page of the unfiled bank transactions in
  # them, the same rows as the page that showed its count, and the state isn't part of that.
  def account_params
    to_params.slice(:account, :date_from, :date_to)
  end

  # The budget's Accounts, alphabetically, for the Account picker and for finding the one that was chosen.
  def accounts
    @accounts ||= budget.accounts.alphabetical.to_a
  end

  # Whether the state's range is optional, so it can be any date.
  def optional_range?
    state.in?(OPTIONAL_RANGE_STATES)
  end

  # Whether a range is in use: every state's is, but for Unfiled and To review it's only there when it was given.
  def range_applies?
    !date_range.any?
  end

  # The budget's bank transactions in the Account that was chosen, or every Account's, which is what the states below narrow.
  def scope
    account ? budget.bank_transactions.where(account_id: account.id) : budget.bank_transactions
  end

  # What "and next" goes through, on a form opened from this list: the Account's bank transactions, and in the range when it's Unfiled's or To review's,
  # which is the range of the unfiled ones that were listed (in the other states they're listed whatever their date).
  def next_scope
    optional_range? && range_applies? ? scope.where(date: date_range.range) : scope
  end

  # The bank transactions the filters leave, as a relation of the budget's own, to be ordered and paged. All is "unfiled, or in the range":
  # every unfiled one whatever its date, and the filed and ignored ones in the range. Unfiled is built with a left join, so it's combined
  # as a subquery on the ids and not with the others directly.
  def bank_transactions
    case state
    when "unfiled" then in_range(scope.unfiled)
    when "to_review" then in_range(scope.to_review)
    when "filed" then scope.filed.where(date: date_range.range)
    when "ignored" then scope.ignored.where(date: date_range.range)
    else scope.where(date: date_range.range).or(scope.where(id: scope.unfiled.select(:id)))
    end
  end

  private
    # Unfiled and To review start with every date, and are narrowed when a range is given.
    def in_range(relation)
      range_applies? ? relation.where(date: date_range.range) : relation
    end
end
