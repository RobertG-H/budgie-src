# Specs never talk to Splitwise, as they never talk to Google. `Splitwise.client` is the one seam, and every example starts with it replaced by a
# SplitwiseFake that answers from what the example told it and records what it was asked, so nothing leaves the machine: Splitwise::Client's own
# spec replaces Net::HTTP instead, and is the only one that reaches the real client.
#
#   splitwise.signs_in("good-code", as: Splitwise::Person.new(id: "4321", name: "Robert G."), token: "its-token")
#   get splitwise_callback_path(code: "good-code", state: state)
#   expect(splitwise.exchanges).to eq([ ... ])
#
# It also holds the person's Splitwise expenses, and answers for them as Splitwise does (a page at a time, filtered by `updated_after` and `dated_after`,
# deleted ones left in), so a sync is exercised against the paging and filtering it will meet:
#
#   splitwise.expense(1001, "Dinner", net_balance: "50.00", date: "2026-10-03")
#   splitwise.edit(1001, net_balance: "60.00")   # in place, and later than it was
#   splitwise.delete(1001)                       # soft: still in the listing, with deleted_at
#   splitwise.restore(1001)
class SplitwiseFake
  AUTHORIZE_URL = "https://secure.splitwise.com/oauth/authorize".freeze

  attr_reader :authorizations, :exchanges, :lookups, :expense_requests

  def initialize(configured: true)
    @configured = configured
    @people = {} # token => Person
    @codes = {}  # code => token
    @failure = nil
    @authorizations = []
    @exchanges = []
    @lookups = []
    @expenses = {} # id => Splitwise::Expense
    @expense_requests = []
    @expense_failures = {} # offset => error, once
    @clock = Time.utc(2026, 10, 5, 12)
  end

  def configured?
    @configured
  end

  # Lets the code `code` be swapped for `token`, which is for `as`. The default is a new token for each code.
  def signs_in(code, as:, token: "token-for-#{code}")
    @codes[code] = token
    @people[token] = as
  end

  # A token that Splitwise has stopped accepting: it's still known to Budgie, and not to Splitwise.
  def revoke(token)
    @people.delete(token)
  end

  # Whatever the next questions it's asked will raise, such as Splitwise being down.
  def fails_with(error)
    @failure = error
  end

  # An expense Splitwise has, which is the person's whoever they are: `net_balance` is their own share. Each change is a minute after the last, so what
  # was updated later says so, as it does at Splitwise. It's strings for dates and money, as Splitwise sends them, and a given `updated_at` is used as it is.
  def expense(id, description = "Expense #{id}", net_balance: "-10.00", date: "2026-10-03", currency_code: "CAD", payment: false, updated_at: nil, deleted_at: nil)
    @expenses[id.to_s] = Splitwise::Expense.new(
      id: id.to_s, description: description, date: (Date.iso8601(date) if date), currency_code: currency_code, payment: payment, updated_at: updated_at || tick,
      deleted_at: deleted_at, net_balance: (BigDecimal(net_balance.to_s) if net_balance)
    )
  end

  # Changes an expense in place, as an edit at Splitwise does: it keeps its id and its `updated_at` moves on.
  def edit(id, **changes)
    current = @expenses.fetch(id.to_s)
    changes[:net_balance] = BigDecimal(changes[:net_balance].to_s) if changes[:net_balance]
    changes[:date] = Date.iso8601(changes[:date]) if changes[:date].is_a?(String)
    @expenses[id.to_s] = current.with(updated_at: tick, **changes)
  end

  # Soft: the expense stays in the listing with `deleted_at` set, and can be restored.
  def delete(id)
    edit(id, deleted_at: @clock)
  end

  def restore(id)
    edit(id, deleted_at: nil)
  end

  # Splitwise with none of the expenses it had, for a spec that starts again.
  def forget_expenses
    @expenses.clear
  end

  # The next request at this offset will raise `error`, such as a sync that's halfway through when Splitwise goes down. It happens once, so the sync that
  # follows is a fresh start.
  def fails_at_offset(offset, error)
    @expense_failures[offset] = error
  end

  # A page of the expenses, as Splitwise answers one: in an order of its own (newest date first), after the ones `updated_after` and `dated_after` leave out,
  # deleted ones included. Both bounds are exclusive here, so an expense dated on the very day a read starts from is only found by a sync that asks from before it.
  def expenses(token, user_id:, limit:, offset:, updated_after: nil, dated_after: nil)
    @expense_requests << { token: token, user_id: user_id, limit: limit, offset: offset, updated_after: updated_after, dated_after: dated_after }
    raise @failure if @failure
    raise @expense_failures.delete(offset) if @expense_failures.key?(offset)
    raise Splitwise::Rejected, "Splitwise doesn't accept the token any more." unless @people.key?(token)

    matching = @expenses.values
    matching = matching.select { |expense| expense.updated_at > updated_after } if updated_after
    matching = matching.select { |expense| expense.date.nil? || expense.date.in_time_zone("UTC") > dated_after } if dated_after
    matching.sort_by { |expense| [ expense.date || Date.new(1970, 1, 1), expense.id.to_i ] }.reverse.slice(offset, limit) || []
  end

  def authorization_url(redirect_uri:, state:)
    @authorizations << { redirect_uri: redirect_uri, state: state }
    "#{AUTHORIZE_URL}?#{{ client_id: "fake-client-id", redirect_uri: redirect_uri, response_type: "code", state: state }.to_query}"
  end

  def exchange_code(code:, redirect_uri:)
    @exchanges << { code: code, redirect_uri: redirect_uri }
    raise @failure if @failure

    @codes.fetch(code) { raise Splitwise::Error, "Splitwise didn't accept the sign-in (400)." }
  end

  def current_user(token)
    @lookups << token
    raise @failure if @failure

    @people.fetch(token) { raise Splitwise::Rejected, "Splitwise doesn't accept the token any more." }
  end

  def inspect
    "#<SplitwiseFake>"
  end

  private
    def tick
      @clock += 1.minute
    end
end

module SplitwiseHelpers
  def splitwise
    Splitwise.client
  end

  # Starts a request for the person to be sent to Splitwise from the form, and answers with the `state` that was sent along.
  def state_sent_to_splitwise
    Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")
  end
end

RSpec.configure do |config|
  config.include SplitwiseHelpers

  config.before { Splitwise.client = SplitwiseFake.new }
  config.after { Splitwise.client = nil }
end
