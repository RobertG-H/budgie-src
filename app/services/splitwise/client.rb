require "net/http"

# Asks Splitwise the questions connecting and syncing need, and nothing else: where to send a person to sign in, what a code they come back with is
# worth, who a token is for, and the expenses they have. It's the real thing behind `Splitwise.client`, and the only code that opens a connection to Splitwise.
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
    person(get("get_current_user", access_token)["user"])
  end

  # A page of the expenses of the person `user_id` is, as Splitwise::Expense values with only their own share of each: `limit` of them from `offset`, the ones
  # that changed since `updated_after` and are dated after `dated_after` when those are given (times, sent as ISO 8601 in UTC). Both the limit and the
  # offset are always sent, since Splitwise's defaults are small and nothing says where a page stops but a short one. Splitwise leaves deleted expenses in the
  # listing, with `deleted_at` set. The order isn't documented, so nothing here depends on it.
  def expenses(access_token, user_id:, limit:, offset:, updated_after: nil, dated_after: nil)
    query = { limit: limit, offset: offset, updated_after: updated_after&.utc&.iso8601, dated_after: dated_after&.utc&.iso8601 }.compact
    list = get("get_expenses", access_token, query)["expenses"]

    Array(list.is_a?(Array) ? list : nil).filter_map { |entry| Splitwise::Expense.from_api(entry, user_id: user_id) }
  end

  def inspect
    "#<#{self.class.name} configured=#{configured?}>"
  end
  alias_method :to_s, :inspect

  private
    # One authorised read of the API, and its answer as a Hash. A token Splitwise won't accept is Rejected, a limit it has put on asking is RateLimited, and anything
    # else that isn't an answer is an Error. Splitwise has two error shapes ({"errors": {"base": [...]}} and {"error": "..."}), answers 403 and 404 for what isn't found
    # as well as what isn't allowed, and sometimes says a failure with a 200, so the body is looked at too. What it says is never repeated: only the status, in words.
    def get(path, access_token, query = {})
      request = Net::HTTP::Get.new("#{API_PATH}/#{path}#{"?#{query.to_query}" if query.any?}")
      request["Authorization"] = "Bearer #{access_token}"
      response = perform(request)

      case response
      when Net::HTTPUnauthorized then raise Splitwise::Rejected, "Splitwise doesn't accept the token any more."
      when Net::HTTPTooManyRequests then raise Splitwise::RateLimited, "Splitwise is limiting how often Budgie can ask."
      when Net::HTTPForbidden, Net::HTTPNotFound then raise Splitwise::Error, "Splitwise says what Budgie asked for wasn't found, or isn't allowed (#{response.code})."
      when Net::HTTPSuccess then parse(response).tap { |body| raise Splitwise::Error, "Splitwise answered with an error." if error_in?(body) }
      else raise Splitwise::Error, "Splitwise answered #{response.code}."
      end
    end

    # An error in either shape. An empty `errors` is how Splitwise says there were none.
    def error_in?(body)
      body["error"].present? || body["errors"].present?
    end

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
