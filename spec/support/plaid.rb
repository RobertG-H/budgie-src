# Specs never talk to Plaid, as they never talk to Splitwise or Google. `PlaidApi.client` is the one seam, and every example starts with it replaced by a
# PlaidFake that answers from what the example told it and records what it was asked, so nothing leaves the machine: PlaidApi::Client's own spec replaces
# Net::HTTP instead, and is the only one that reaches the real client.
#
#   plaid.links("public-1", item_id: "item-1", institution_id: "ins_42", institution_name: "TD Canada Trust",
#     accounts: [ plaid.account("acc-1", "TD Every Day Chequing", mask: "4821"), plaid.account("acc-2", "TD U.S. Dollar", currency: "USD") ])
#   post plaid_choice_path, params: { ... }
#   expect(plaid.exchanges).to eq([ "public-1" ])
#   expect(plaid.removals).to eq([ "access-for-public-1" ])
class PlaidFake
  attr_reader :link_tokens, :exchanges, :account_requests, :removals

  def initialize(configured: true)
    @configured = configured
    @links = {}    # public token => { exchange:, accounts: }
    @items = {}    # access token => PlaidApi::Accounts
    @failures = {} # method => error
    @link_tokens = []
    @exchanges = []
    @account_requests = []
    @removals = []
  end

  def configured?
    @configured
  end

  # Lets `public_token` be swapped for an Item with these accounts at this bank, whose access token is `access_token`.
  def links(public_token, item_id: "item-for-#{public_token}", institution_id: "ins_42", institution_name: "TD Canada Trust", accounts: [], access_token: "access-for-#{public_token}")
    @links[public_token] = PlaidApi::Exchange.new(access_token: access_token, item_id: item_id)
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

  def create_link_token(client_user_id:)
    @link_tokens << client_user_id
    fail_if(:create_link_token)
    "link-sandbox-#{@link_tokens.size}"
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
      raise @failures[method] if @failures.key?(method)
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
