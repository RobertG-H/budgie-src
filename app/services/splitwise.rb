# Splitwise, which a budget connects an Account to (ADR 0016). This is the one place the rest of the app meets it: `Splitwise.client` is the seam, so
# that what asks Splitwise questions (Splitwise::Client) can be replaced, and specs replace it and never call Splitwise, as they never call Google.
#
# Connecting isn't signing in to Budgie: the OAuth 2 authorization-code flow is Budgie's own (SplitwiseConnectionsController and
# SplitwiseCallbacksController), not an OmniAuth provider, since nothing here decides who a person is.
module Splitwise
  # Splitwise couldn't be asked, or didn't give an answer that can be used. The message says so in words for a person, and never carries a token, a
  # code, the client's secret or anything Splitwise answered with.
  class Error < StandardError; end

  # Splitwise doesn't accept a token any more: it was revoked, or the person removed Budgie from their Splitwise apps. A sync that finds this
  # says the connection needs reconnecting.
  class Rejected < Error; end

  # Who signed in to Splitwise, and all that's kept of them: their Splitwise user's id, and the name Splitwise shows for them ("Robert G."). Not their email.
  Person = Data.define(:id, :name)

  class << self
    # What asks Splitwise questions. The real one is made from the environment on first use; specs assign another.
    def client
      @client ||= Client.new(client_id: ENV["SPLITWISE_CLIENT_ID"], client_secret: ENV["SPLITWISE_CLIENT_SECRET"])
    end

    attr_writer :client

    # Whether Budgie can connect to Splitwise at all: the app's client id and secret are set, and so are the keys the token is encrypted with. Without them
    # "Connect Splitwise" isn't offered, and a person is never taken to Splitwise to sign in and then told there's nowhere to keep the token.
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
