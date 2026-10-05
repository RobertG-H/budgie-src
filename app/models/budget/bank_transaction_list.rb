# The bank transactions of a budget, of every Account and in any state, for the Bank transactions page. It's made from the params the
# page is given, `filter`, which it reads the way a page does and never trusts: what it doesn't understand is dropped, so `to_params` is
# always something it understood and nothing a person sent (as Budget::RecordList does for the Records page).
#
# - `state` is `all` (the default), `unfiled`, `filed` or `ignored`.
# - `account` is the id of one of the budget's Accounts; blank, unknown or another budget's is all Accounts.
# - `date_from` and `date_to` are a DateRangeFilter, and apply to a bank transaction's `date` in every state but Unfiled: every unfiled
#   bank transaction is always listed whatever its date, so one is never lost to a range, and in All it's listed together with the filed
#   and ignored ones in the range.
#
# Everything is found through the budget's Accounts, so another budget's bank transactions never appear.
class Budget::BankTransactionList
  STATES = %w[ all unfiled filed ignored ].freeze

  attr_reader :budget, :date_range, :state, :account

  # `filter` is what the page was given: ActionController::Parameters, a Hash, or anything at all.
  def self.parse(budget, filter)
    values = Budget::FilterValues.read(filter)

    new(budget, date_range: DateRangeFilter.new(from: values[:date_from], to: values[:date_to]), state: values[:state], account_id: values[:account])
  end

  def initialize(budget, date_range:, state: nil, account_id: nil)
    @budget = budget
    @date_range = date_range
    @state = (state.presence_in(STATES) if state.is_a?(String)) || "all"
    @account = accounts.find { |candidate| candidate.id.to_s == account_id } if account_id.is_a?(String) && account_id.match?(/\A\d+\z/)
  end

  # What was understood, as the params that spell it, for a link or a hidden field. A state of All is the default and isn't said.
  def to_params
    date_range.to_params.merge(state: (state unless state == "all"), account: account&.id&.to_s).compact
  end

  # Only the Account, which is all that "File N as guessed" carries: it reviews and files one page of the unfiled bank transactions, and
  # neither the state nor the dates are part of that.
  def account_params
    to_params.slice(:account)
  end

  # The same Account's unfiled bank transactions, which is what "File N as guessed" is about.
  def unfiled
    self.class.new(budget, date_range: date_range, state: "unfiled", account_id: account&.id&.to_s)
  end

  # The budget's Accounts, alphabetically, for the Account picker and for finding the one that was chosen.
  def accounts
    @accounts ||= budget.accounts.alphabetical.to_a
  end

  # Whether the range is used: it is in every state but Unfiled, which lists every unfiled bank transaction whatever its date.
  def range_applies?
    state != "unfiled"
  end

  # The bank transactions the filters leave, as a relation of the budget's own, to be ordered and paged. All is "unfiled, or in the range":
  # every unfiled one whatever its date, and the filed and ignored ones in the range. Unfiled is built with a left join, so it's combined
  # as a subquery on the ids and not with the others directly.
  def bank_transactions
    scope = account ? budget.bank_transactions.where(account_id: account.id) : budget.bank_transactions

    case state
    when "unfiled" then scope.unfiled
    when "filed" then scope.filed.where(date: date_range.range)
    when "ignored" then scope.ignored.where(date: date_range.range)
    else scope.where(date: date_range.range).or(scope.where(id: scope.unfiled.select(:id)))
    end
  end
end
