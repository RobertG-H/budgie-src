# Specs never talk to Plaid, as they never talk to Splitwise or Google. `PlaidApi.client` is the one seam, and every example starts with it replaced by a
# PlaidFake that answers from what the example told it and records what it was asked, so nothing leaves the machine: PlaidApi::Client's own spec replaces
# Net::HTTP instead, and is the only one that reaches the real client.
#
#   plaid.links("public-1", item_id: "item-1", institution_id: "ins_42", institution_name: "TD Canada Trust",
#     accounts: [ plaid.account("acc-1", "TD Every Day Chequing", mask: "4821"), plaid.account("acc-2", "TD U.S. Dollar", currency: "USD") ])
#   post plaid_choice_path, params: { ... }
#   expect(plaid.exchanges).to eq([ "public-1" ])
#   expect(plaid.removals).to eq([ "access-for-public-1" ])
#
# For syncing, it keeps each access token's transactions as Plaid does, as a list of changes that a cursor is a place in, and answers a page of them at a time:
#
#   plaid.adds("access-sandbox-token", plaid.transaction("tx-1", account: "acc-1", amount: "82.45", description: "LOBLAWS #1234"))
#   plaid.modifies("access-sandbox-token", plaid.transaction("tx-1", account: "acc-1", amount: "80.00"))
#   plaid.removes("access-sandbox-token", "tx-1", account: "acc-1")
#   plaid.transactions_page_size = 2                      # Plaid's is 500, which a spec needn't make to see paging
#   plaid.mutates_during_paging { plaid.adds(...) }       # the next page after the first fails as Plaid's does, once, after the block changes what there is
#   plaid.fails_once(:transactions_sync, error)           # the next call raises, and the one after answers
#   plaid.not_ready("access-sandbox-token")               # answers nothing and an empty cursor until `ready`
#   expect(plaid.transaction_requests).to eq([ [ "access-sandbox-token", nil ] ])
#
# For a connection that's already there (Reconnect and Choose accounts), it's told what the Item's accounts are, which is also how a spec changes what's shared,
# and records each update-mode link token it was asked for:
#
#   plaid.item("access-sandbox-token", accounts: [ plaid.account("acc-1", "TD Every Day Chequing") ])
#   expect(plaid.update_link_tokens).to eq([ { access_token: "access-sandbox-token", client_user_id: budget.id, account_selection: true } ])
class PlaidFake
  attr_reader :link_tokens, :update_link_tokens, :exchanges, :account_requests, :removals, :transaction_requests
  attr_accessor :transactions_page_size

  def initialize(configured: true)
    @configured = configured
    @links = {}    # public token => { exchange:, accounts: }
    @items = {}    # access token => PlaidApi::Accounts
    @failures = {} # method => error
    @link_tokens = []
    @update_link_tokens = []
    @exchanges = []
    @account_requests = []
    @removals = []
    @changes = Hash.new { |hash, token| hash[token] = [] } # access token => [ [ :added | :modified | :removed, transaction ] ]
    @not_ready = Set.new
    @failures_once = {}
    @transaction_requests = []
    @transactions_page_size = PlaidApi::Client::TRANSACTIONS_PAGE_SIZE
    @paging = false
  end

  def configured?
    @configured
  end

  # Lets `public_token` be swapped for an Item with these accounts at this bank, whose access token is `access_token`.
  def links(public_token, item_id: "item-for-#{public_token}", institution_id: "ins_42", institution_name: "TD Canada Trust", accounts: [], access_token: "access-for-#{public_token}")
    @links[public_token] = PlaidApi::Exchange.new(access_token: access_token, item_id: item_id)
    @items[access_token] = PlaidApi::Accounts.new(item_id: item_id, institution_id: institution_id, institution_name: institution_name, accounts: accounts)
  end

  # The Item `access_token` reads has these accounts, as `/accounts/get` answers once the person has chosen them in Link: whatever it had before is replaced.
  def item(access_token, accounts:, item_id: "item-for-#{access_token}", institution_id: "ins_42", institution_name: "TD Canada Trust")
    @items[access_token] = PlaidApi::Accounts.new(item_id: item_id, institution_id: institution_id, institution_name: institution_name, accounts: accounts)
  end

  # One of a bank's accounts as `/accounts/get` says it.
  def account(id, name = "Account #{id}", mask: "0000", subtype: "checking", type: "depository", currency: "CAD", unofficial_currency: nil, balance: "100.00")
    PlaidApi::Account.new(id: id, name: name, official_name: nil, mask: mask, type: type, subtype: subtype, iso_currency_code: currency,
      unofficial_currency_code: unofficial_currency, current_balance: BigDecimal(balance), available_balance: nil)
  end

  # The next call of `method` (such as :exchange_public_token) raises `error`, and so does every one after it.
  def fails(method, error)
    @failures[method] = error
  end

  # The next call of `method` raises `error`, and the ones after it answer as usual.
  def fails_once(method, error)
    @failures_once[method] = error
  end

  # One of a bank's transactions as `/transactions/sync` says it, posted and in CAD unless told otherwise. `amount` is signed as Plaid signs it, positive for
  # money out, and `description` is the bank's own (`original_description`).
  def transaction(id, account:, amount: "10.00", date: "2026-10-03", description: "LOBLAWS #1234", name: "Loblaws", authorized_date: nil, currency: "CAD",
    unofficial_currency: nil, pending: false)
    PlaidApi::Transaction.new(id: id, account_id: account, amount: amount && BigDecimal(amount), iso_currency_code: currency, unofficial_currency_code: unofficial_currency,
      date: date && Date.iso8601(date), authorized_date: authorized_date && Date.iso8601(authorized_date), original_description: description, name: name, pending: pending)
  end

  # What the bank's transactions do next, in order, as a sync after this reads them.
  def adds(access_token, *transactions)
    transactions.each { @changes[access_token] << [ :added, it ] }
  end

  def modifies(access_token, *transactions)
    transactions.each { @changes[access_token] << [ :modified, it ] }
  end

  def removes(access_token, *ids, account:)
    ids.each { @changes[access_token] << [ :removed, PlaidApi::RemovedTransaction.new(id: it, account_id: account) ] }
  end

  # Plaid hasn't gathered the bank's history yet: it answers nothing, with an empty cursor, until it has.
  def not_ready(access_token)
    @not_ready << access_token
  end

  def ready(access_token)
    @not_ready.delete(access_token)
  end

  # The next request for a page after the first of a sync finds what there is changed, which the block does, and fails as Plaid does
  # (TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION), once.
  def mutates_during_paging(&block)
    @mutation = block
  end

  # A page of the changes after the cursor, which is the place in the list of changes it names ("cursor-3"), or the start without one.
  def transactions_sync(access_token, cursor:)
    @transaction_requests << [ access_token, cursor ]
    fail_if(:transactions_sync)
    mutate if @mutation && @paging
    return PlaidApi::TransactionsPage.new(added: [], modified: [], removed: [], next_cursor: "", has_more: false) if @not_ready.include?(access_token)
    changes = @changes.fetch(access_token, [])
    start = cursor ? Integer(cursor.delete_prefix("cursor-")) : 0
    page = changes[start, transactions_page_size] || []
    finish = start + page.size
    @paging = finish < changes.size
    by_kind = page.group_by(&:first).transform_values { it.map(&:last) }

    PlaidApi::TransactionsPage.new(added: by_kind.fetch(:added, []), modified: by_kind.fetch(:modified, []), removed: by_kind.fetch(:removed, []),
      next_cursor: "cursor-#{finish}", has_more: @paging)
  end

  def create_link_token(client_user_id:)
    @link_tokens << client_user_id
    fail_if(:create_link_token)
    "link-sandbox-#{@link_tokens.size}"
  end

  def create_update_link_token(access_token:, client_user_id:, account_selection: false)
    @update_link_tokens << { access_token: access_token, client_user_id: client_user_id, account_selection: account_selection }
    fail_if(:create_update_link_token)
    "link-sandbox-update-#{@update_link_tokens.size}"
  end

  def exchange_public_token(public_token)
    @exchanges << public_token
    fail_if(:exchange_public_token)
    @links.fetch(public_token) { raise PlaidApi::Error.new(error_code: "INVALID_PUBLIC_TOKEN") }
  end

  def accounts(access_token)
    @account_requests << access_token
    fail_if(:accounts)
    @items.fetch(access_token) { raise PlaidApi::Error.new(error_code: "INVALID_ACCESS_TOKEN") }
  end

  def remove_item(access_token)
    @removals << access_token
    fail_if(:remove_item)
    nil
  end

  def inspect
    "#<PlaidFake>"
  end

  private
    def fail_if(method)
      raise @failures_once.delete(method) if @failures_once.key?(method)
      raise @failures[method] if @failures.key?(method)
    end

    def mutate
      mutation, @mutation, @paging = @mutation, nil, false
      mutation.call
      raise PlaidApi::Error.new(error_code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", error_type: "TRANSACTIONS_ERROR", status: 400)
    end
end

module PlaidHelpers
  def plaid
    PlaidApi.client
  end
end

RSpec.configure do |config|
  config.include PlaidHelpers

  config.before { PlaidApi.client = PlaidFake.new }
  config.after { PlaidApi.client = nil }
end
