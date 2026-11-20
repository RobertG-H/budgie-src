require "net/http"

# Asks Plaid the questions connecting a bank and syncing it need: a link token for Plaid Link to open with, what the public token Link gives back is worth,
# which accounts an Item has, what changed in its transactions since a cursor, and removing an Item. It's the real thing behind `PlaidApi.client`, and the only code that opens a connection to Plaid.
#
# Every request is a JSON POST with the client's id and secret in Plaid's headers, never in the body, so they can't end up in anything that shows a body. Neither
# appears in an error, nor in `inspect`, and nor does a token: an error carries only Plaid's error code and the message Plaid writes for a person. Every failure
# to get an answer is a PlaidApi::Error, so a caller needs one rescue. Money is read from the JSON's own text as a decimal, never through a float.
class PlaidApi::Client
  # Seconds. Connecting waits on a person's request, so Plaid being slow mustn't hold a server thread for long.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  # What can go wrong between here and Plaid that isn't an answer.
  UNREACHABLE = [ SocketError, SystemCallError, Timeout::Error, IOError, EOFError, OpenSSL::SSL::SSLError ].freeze

  # What a new connection's link token asks for (ADR 0018). `days_requested` is the most Plaid allows, since an Item's history can't be raised later and the date
  # each Account reads from decides what's kept; Link offers only bank and credit card accounts; and there's no webhook and no redirect URI, so Plaid never calls
  # Budgie and no host needs registering (docs/research/plaid-link-rails-importmap.md).
  LINK_SETTINGS = {
    client_name: "Budgie",
    language: "en",
    country_codes: [ "CA" ],
    products: [ "transactions" ],
    transactions: { days_requested: 730 },
    account_filters: { depository: { account_subtypes: [ "all" ] }, credit: { account_subtypes: [ "all" ] } }
  }.freeze

  def initialize(client_id:, secret:, environment:)
    @client_id = client_id.presence
    @secret = secret.presence
    @host = PlaidApi::HOSTS[environment.to_s]
  end

  # Whether Budgie has a Plaid team's keys and knows which of Plaid's environments they're for.
  def configured?
    @client_id.present? && @secret.present? && @host.present?
  end

  # What an update-mode link token asks for: Link's own settings and none of a new Item's, since its products and history were decided when it was made.
  UPDATE_LINK_SETTINGS = LINK_SETTINGS.slice(:client_name, :language, :country_codes).freeze

  # A link token for Plaid Link to open with, for a new connection. `client_user_id` says who it's for, which is the budget's id and never anything personal.
  def create_link_token(client_user_id:)
    link_token(**LINK_SETTINGS, user: { client_user_id: client_user_id.to_s })
  end

  # A link token for Plaid Link's update mode on an Item that's already connected, which keeps the Item and its account ids, so its access token doesn't change and
  # there's nothing to exchange afterwards: Reconnect signs in to the bank again, and with `account_selection` (Choose accounts) the person also changes which of
  # the bank's accounts are shared, from the same kinds Connect offers. It lasts 30 minutes.
  def create_update_link_token(access_token:, client_user_id:, account_selection: false)
    selection = { update: { account_selection_enabled: true }, account_filters: LINK_SETTINGS[:account_filters] } if account_selection
    link_token(**UPDATE_LINK_SETTINGS, user: { client_user_id: client_user_id.to_s }, access_token: access_token, **selection.to_h)
  end

  # What the public token Link gave back is worth: the Item's access token and id. Each exchange makes an Item, which on Plaid's Trial is one of ten for good.
  def exchange_public_token(public_token)
    body = post("/item/public_token/exchange", public_token: public_token)
    token = body["access_token"]
    item_id = body["item_id"]
    raise PlaidApi::Error, "Plaid sent no connection." unless token.is_a?(String) && token.present? && item_id.is_a?(String) && item_id.present?

    PlaidApi::Exchange.new(access_token: token, item_id: item_id)
  end

  # The Item's accounts, as PlaidApi::Accounts. What gets stored about a connection's accounts comes from here and never from what the browser sent.
  def accounts(access_token)
    body = post("/accounts/get", access_token: access_token)
    item = body["item"].is_a?(Hash) ? body["item"] : {}
    list = body["accounts"].is_a?(Array) ? body["accounts"] : []

    PlaidApi::Accounts.new(
      item_id: text(item["item_id"]), institution_id: text(item["institution_id"]), institution_name: text(item["institution_name"]),
      accounts: list.filter_map { account(it) }
    )
  end

  # How many transactions to ask `/transactions/sync` for at once, which is the most Plaid gives.
  TRANSACTIONS_PAGE_SIZE = 500

  # One page of what changed in the Item's transactions since `cursor` (none the first time, which is the whole history), as a PlaidApi::TransactionsPage. The bank's
  # own description is asked for on every call, the first included, since a transaction already sent without it isn't sent again.
  def transactions_sync(access_token, cursor:)
    body = post("/transactions/sync", access_token: access_token, **({ cursor: cursor } if cursor), count: TRANSACTIONS_PAGE_SIZE,
      options: { include_original_description: true })

    PlaidApi::TransactionsPage.new(
      added: list(body["added"]).filter_map { transaction(it) }, modified: list(body["modified"]).filter_map { transaction(it) },
      removed: list(body["removed"]).filter_map { removed_transaction(it) }, next_cursor: body["next_cursor"].is_a?(String) ? body["next_cursor"] : "",
      has_more: body["has_more"] == true
    )
  end

  # Removes the Item: Plaid stops reading the bank for Budgie, and stops billing for it. The access token stops working.
  def remove_item(access_token)
    post("/item/remove", access_token: access_token)
    nil
  end

  def inspect
    "#<#{self.class.name} configured=#{configured?} host=#{@host.inspect}>"
  end
  alias_method :to_s, :inspect

  private
    def link_token(**payload)
      token = post("/link/token/create", **payload)["link_token"]
      raise PlaidApi::Error, "Plaid sent no link." unless token.is_a?(String) && token.present?

      token
    end

    # One request, and its answer as a Hash. Plaid answers an error with a non-success status and a JSON body of `error_code` and `display_message` (and a message
    # for developers, which is never repeated); anything else that isn't an answer is said by its status alone.
    def post(path, **payload)
      request = Net::HTTP::Post.new(path)
      request["Content-Type"] = "application/json"
      request["PLAID-CLIENT-ID"] = @client_id
      request["PLAID-SECRET"] = @secret
      request.body = payload.to_json
      response = perform(request)
      body = parse(response)

      return body if response.is_a?(Net::HTTPSuccess)
      if body["error_code"].present?
        raise PlaidApi::Error.new(error_code: text(body["error_code"]), error_type: text(body["error_type"]), display_message: text(body["display_message"]),
          status: response.code.to_i)
      end

      raise PlaidApi::Error.new("Plaid answered #{response.code}.", status: response.code.to_i)
    end

    def perform(request)
      Net::HTTP.start(@host, 443, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }
    rescue *UNREACHABLE
      raise PlaidApi::Error, "Plaid couldn't be reached."
    end

    # Plaid answers JSON, but a proxy's error page isn't. Numbers with a point are read as decimals from their own text.
    def parse(response)
      body = JSON.parse(response.body.to_s, decimal_class: BigDecimal)
      body.is_a?(Hash) ? body : {}
    rescue JSON::ParserError
      {}
    end

    def account(entry)
      return unless entry.is_a?(Hash) && (id = text(entry["account_id"]))

      balances = entry["balances"].is_a?(Hash) ? entry["balances"] : {}
      PlaidApi::Account.new(
        id: id, name: text(entry["name"]), official_name: text(entry["official_name"]), mask: text(entry["mask"]), type: text(entry["type"]),
        subtype: text(entry["subtype"]), iso_currency_code: text(balances["iso_currency_code"]), unofficial_currency_code: text(balances["unofficial_currency_code"]),
        current_balance: decimal(balances["current"]), available_balance: decimal(balances["available"])
      )
    end

    def list(value)
      value.is_a?(Array) ? value : []
    end

    # A transaction with no id can't be matched to anything, so it's left out; anything else that can't be read is nil, for the sync to judge.
    def transaction(entry)
      return unless entry.is_a?(Hash) && (id = text(entry["transaction_id"]))

      PlaidApi::Transaction.new(
        id: id, account_id: text(entry["account_id"]), amount: decimal(entry["amount"]), iso_currency_code: text(entry["iso_currency_code"]),
        unofficial_currency_code: text(entry["unofficial_currency_code"]), date: date(entry["date"]), authorized_date: date(entry["authorized_date"]),
        original_description: entry["original_description"].is_a?(String) ? entry["original_description"] : nil,
        name: entry["name"].is_a?(String) ? entry["name"] : nil, pending: entry["pending"] == true
      )
    end

    def removed_transaction(entry)
      return unless entry.is_a?(Hash) && (id = text(entry["transaction_id"]))

      PlaidApi::RemovedTransaction.new(id: id, account_id: text(entry["account_id"]))
    end

    def date(value)
      Date.iso8601(value) if value.is_a?(String)
    rescue Date::Error
      nil
    end

    def text(value)
      value.to_s.strip.presence if value.is_a?(String) || value.is_a?(Numeric)
    end

    # A whole number comes back from the parser as an Integer, and one with a point as a BigDecimal already.
    def decimal(value)
      BigDecimal(value.to_s) if value.is_a?(Numeric)
    end
end
