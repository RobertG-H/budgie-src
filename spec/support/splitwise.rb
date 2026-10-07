# Specs never talk to Splitwise, as they never talk to Google. `Splitwise.client` is the one seam, and every example starts with it replaced by a
# SplitwiseFake that answers from what the example told it and records what it was asked, so nothing leaves the machine: Splitwise::Client's own
# spec replaces Net::HTTP instead, and is the only one that reaches the real client.
#
#   splitwise.signs_in("good-code", as: Splitwise::Person.new(id: "4321", name: "Robert G."), token: "its-token")
#   get splitwise_callback_path(code: "good-code", state: state)
#   expect(splitwise.exchanges).to eq([ ... ])
class SplitwiseFake
  AUTHORIZE_URL = "https://secure.splitwise.com/oauth/authorize".freeze

  attr_reader :authorizations, :exchanges, :lookups

  def initialize(configured: true)
    @configured = configured
    @people = {} # token => Person
    @codes = {}  # code => token
    @failure = nil
    @authorizations = []
    @exchanges = []
    @lookups = []
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
