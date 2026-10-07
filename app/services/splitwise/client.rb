require "net/http"

# Asks Splitwise the questions connecting needs, and nothing else yet: where to send a person to sign in, what a code they come back with is
# worth, and who a token is for. It's the real thing behind `Splitwise.client`, and the only code that opens a connection to Splitwise.
#
# The token is only ever sent as a Bearer token to Splitwise, and the client's secret only in the token request's body. Neither appears in an error, and
# neither in `inspect`: an error says what went wrong in words and never what Splitwise answered. Every failure to get an answer is a
# Splitwise::Error (and a token Splitwise no longer accepts, a Splitwise::Rejected), so a caller needs one rescue.
class Splitwise::Client
  HOST = "secure.splitwise.com"
  AUTHORIZE_PATH = "/oauth/authorize"
  TOKEN_PATH = "/oauth/token"
  API_PATH = "/api/v3.0"

  # Seconds. Connecting waits on a person's request, so Splitwise being slow mustn't hold a server thread for long.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # What can go wrong between here and Splitwise that isn't an answer.
  UNREACHABLE = [ SocketError, SystemCallError, Timeout::Error, IOError, EOFError, OpenSSL::SSL::SSLError ].freeze

  def initialize(client_id:, client_secret:)
    @client_id = client_id.presence
    @client_secret = client_secret.presence
  end

  # Whether the app has been registered with Splitwise: it has a client id and a secret to prove it with.
  def configured?
    @client_id.present? && @client_secret.present?
  end

  # Where to send a person to sign in to Splitwise and allow Budgie to read their expenses. `state` is a random value that comes back with them, so
  # that a callback that wasn't asked for is refused; `redirect_uri` is where they come back to, which has to be the one registered with Splitwise.
  def authorization_url(redirect_uri:, state:)
    query = { response_type: "code", client_id: @client_id, redirect_uri: redirect_uri, state: state }.to_query
    URI::HTTPS.build(host: HOST, path: AUTHORIZE_PATH, query: query).to_s
  end

  # What the code Splitwise sent them back with is worth: an access token.
  def exchange_code(code:, redirect_uri:)
    request = Net::HTTP::Post.new(TOKEN_PATH)
    request.set_form_data(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri, client_id: @client_id, client_secret: @client_secret)
    response = perform(request)
    raise Splitwise::Error, "Splitwise didn't accept the sign-in (#{response.code})." unless response.is_a?(Net::HTTPSuccess)

    token = parse(response)["access_token"]
    raise Splitwise::Error, "Splitwise sent no token." unless token.is_a?(String) && token.present?

    token
  end

  # Who the token is for.
  def current_user(access_token)
    request = Net::HTTP::Get.new("#{API_PATH}/get_current_user")
    request["Authorization"] = "Bearer #{access_token}"
    response = perform(request)
    raise Splitwise::Rejected, "Splitwise doesn't accept the token any more." if response.is_a?(Net::HTTPUnauthorized)
    raise Splitwise::Error, "Splitwise answered #{response.code}." unless response.is_a?(Net::HTTPSuccess)

    person(parse(response)["user"])
  end

  def inspect
    "#<#{self.class.name} configured=#{configured?}>"
  end
  alias_method :to_s, :inspect

  private
    def perform(request)
      Net::HTTP.start(HOST, 443, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }
    rescue *UNREACHABLE
      raise Splitwise::Error, "Splitwise couldn't be reached."
    end

    # Splitwise answers JSON, but a proxy's error page isn't, and neither is anything that has gone wrong in between.
    def parse(response)
      body = JSON.parse(response.body.to_s)
      body.is_a?(Hash) ? body : {}
    rescue JSON::ParserError
      {}
    end

    # Splitwise shows a person as their first name and the initial of their last, "Robert G.", which is what the connection says it's synced as.
    def person(user)
      id = user.is_a?(Hash) ? user["id"] : nil
      raise Splitwise::Error, "Splitwise didn't say who signed in." if id.blank?

      first = user["first_name"].to_s.squish
      last = user["last_name"].to_s.squish
      name = [ first.presence, (last.first + "." if last.present?) ].compact.join(" ").presence || "Splitwise user"

      Splitwise::Person.new(id: id.to_s, name: name)
    end
end
