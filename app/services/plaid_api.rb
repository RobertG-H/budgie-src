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
  class Error < StandardError
    attr_reader :error_code, :display_message

    def initialize(message = nil, error_code: nil, display_message: nil)
      @error_code = error_code.presence
      @display_message = display_message.presence
      super(message || @display_message || ("Plaid refused it (#{@error_code})." if @error_code) || "Plaid couldn't do it.")
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

    private
      # Through the predicates, since the readers raise when a key is missing, and a page that asks must never be a 500 on a host that has none.
      def token_encryption_keys?
        config = ActiveRecord::Encryption.config
        config.has_primary_key?.present? && config.has_key_derivation_salt?.present?
      end
  end
end
