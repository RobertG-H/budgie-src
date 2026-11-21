# Plaid, which a budget connects a bank through (ADR 0018). This is the one place the rest of the app meets it: `PlaidApi.client` is the seam, so that what asks
# Plaid questions (PlaidApi::Client) can be replaced, and specs replace it and never call Plaid, as they never call Splitwise or Google. It's named PlaidApi and
# not Plaid so that it can never clash with the `plaid` gem's constant, which Budgie doesn't use.
#
# Plaid Link runs in the browser (the `plaid-link` Stimulus controller), and only the link token it opens with, the exchange of what it gives back, and the
# questions about the connection that follows need the client's id and secret, which never leave the server.
module PlaidApi
  # The environments Budgie runs against, and the API host each answers on. Development and testing use Sandbox; production uses Production.
  HOSTS = { "sandbox" => "sandbox.plaid.com", "production" => "production.plaid.com" }.freeze

  # Plaid couldn't be asked, or didn't give an answer that can be used. It carries Plaid's `error_code` and the `display_message` Plaid writes for a person, when
  # Plaid gave them, and its message is that, or the code: never a token, the client's secret or Plaid's whole answer.
  # `error_type` is Plaid's category for it (such as ITEM_ERROR or RATE_LIMIT_EXCEEDED) and `status` the HTTP status it came with, when it came from an answer.
  class Error < StandardError
    attr_reader :error_code, :error_type, :display_message, :status

    def initialize(message = nil, error_code: nil, error_type: nil, display_message: nil, status: nil)
      @error_code = error_code.presence
      @error_type = error_type.presence
      @display_message = display_message.presence
      @status = status
      super(message || @display_message || ("Plaid refused it (#{@error_code})." if @error_code) || "Plaid couldn't do it.")
    end

    # Plaid is being asked too often, which is said by its status, its type or its code, depending on the endpoint: nothing is wrong that waiting won't put right.
    def rate_limited?
      status == 429 || error_type == "RATE_LIMIT_EXCEEDED" || error_code == "RATE_LIMIT_EXCEEDED"
    end
  end

  # What a public token is worth: the Item's access token, which reads it from then on, and the Item's id. The token is never shown.
  Exchange = Data.define(:access_token, :item_id) do
    def inspect
      "#<#{self.class.name} item_id=#{item_id.inspect}>"
    end
    alias_method :to_s, :inspect
  end

  # One of the bank's accounts as `/accounts/get` says it: Plaid's id, name and mask (its last digits), its kind, and its currency. Balances are decimals read from
  # the JSON's own text, never through a float, though Budgie keeps none (ADR 0001).
  Account = Data.define(:id, :name, :official_name, :mask, :type, :subtype, :iso_currency_code, :unofficial_currency_code, :current_balance, :available_balance) do
    # Its currency, which is an unofficial one (such as a cryptocurrency's) when Plaid gives one.
    def currency
      unofficial_currency_code.presence || iso_currency_code
    end

    # Whether it's in `code`, an ISO currency, which an account with an unofficial currency never is.
    def in_currency?(code)
      unofficial_currency_code.blank? && iso_currency_code == code
    end
  end

  # What `/accounts/get` answers: the Item it's for (its id, and the bank's Plaid id and name) and its accounts.
  Accounts = Data.define(:item_id, :institution_id, :institution_name, :accounts)

  # One of the bank's transactions as `/transactions/sync` says it, added or modified, which is everything Budgie reads of it: every field but the id may be
  # missing (nil), and anything else Plaid sends is left out. `amount` is signed as Plaid signs it, positive for money out, and is a decimal read from the JSON's
  # own text. `date` is the date it posted on, for a posted one, and `authorized_date` when it was authorised. `original_description` is the bank's own words for
  # it, and `name` Plaid's tidied version, which it no longer maintains.
  Transaction = Data.define(:id, :account_id, :amount, :iso_currency_code, :unofficial_currency_code, :date, :authorized_date, :original_description, :name, :pending) do
    # Whether it's in `code`, an ISO currency, which one with an unofficial currency never is.
    def in_currency?(code)
      unofficial_currency_code.blank? && iso_currency_code == code
    end
  end

  # A transaction the bank no longer has, which is all Plaid says of it: its id and its account's.
  RemovedTransaction = Data.define(:id, :account_id)

  # One page of `/transactions/sync`: what was added, modified and removed since the cursor it was asked from, and the cursor to ask from next. `has_more` says
  # there's another page; `next_cursor` is empty while Plaid hasn't gathered the bank's history yet.
  TransactionsPage = Data.define(:added, :modified, :removed, :next_cursor, :has_more)

  class << self
    # What asks Plaid questions. The real one is made from the environment on first use; specs assign another.
    def client
      @client ||= Client.new(client_id: ENV["PLAID_CLIENT_ID"], secret: ENV["PLAID_SECRET"], environment: ENV["PLAID_ENV"])
    end

    attr_writer :client

    # Whether Budgie can connect a bank at all: the client id, secret and environment are set, and so are the keys the token is encrypted with. Without them
    # "Connect a bank" isn't offered, and its pages turn a request away.
    def configured?
      client.configured? && token_encryption_keys?
    end

    # Whether `budget` can use Plaid: it's set up on this host, and the operator has turned it on for the budget's person (User#feature?), since each Item the Trial
    # gives is spent for good. Everything that offers Plaid to a budget, or calls Plaid for one, asks this and not `configured?`, so a person without it is exactly as
    # if Plaid weren't set up: nothing is offered, its pages turn them away, and their connections aren't synced, while what they have stays as it is.
    def available_to?(budget)
      return false unless budget && configured?

      budget.user.feature?(:plaid)
    end

    private
      # Through the predicates, since the readers raise when a key is missing, and a page that asks must never be a 500 on a host that has none.
      def token_encryption_keys?
        config = ActiveRecord::Encryption.config
        config.has_primary_key?.present? && config.has_key_derivation_salt?.present?
      end
  end
end
