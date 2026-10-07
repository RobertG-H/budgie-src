require "rails_helper"

# The real client, which specs never otherwise reach: every other spec has Splitwise.client replaced (spec/support/splitwise.rb). Here only
# Net::HTTP is, so nothing leaves the machine, and what's checked is what the client asks Splitwise and how it reads the answer.
RSpec.describe Splitwise::Client do
  subject(:client) { described_class.new(client_id: "the-client-id", client_secret: "the-client-secret") }

  # The requests that would have been sent, and the answer Splitwise gives to the next one.
  let(:sent) { [] }
  let(:connections) { [] }

  def answer(status, body = {})
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s).new("1.1", status.to_s, "")
    allow(response).to receive(:body).and_return(body.is_a?(String) ? body : body.to_json)
    requests = sent
    http = Object.new
    http.define_singleton_method(:request) do |request|
      requests << request
      response
    end
    opened = connections
    allow(Net::HTTP).to receive(:start) do |host, port, **options, &block|
      opened << { host: host, port: port, **options }
      block.call(http)
    end
  end

  describe "#configured?" do
    it "needs both the client id and the secret" do
      expect(described_class.new(client_id: "id", client_secret: "secret")).to be_configured
      expect(described_class.new(client_id: "id", client_secret: nil)).not_to be_configured
      expect(described_class.new(client_id: "", client_secret: "secret")).not_to be_configured
      expect(described_class.new(client_id: nil, client_secret: nil)).not_to be_configured
    end
  end

  describe "#authorization_url" do
    it "sends the person to Splitwise's own sign-in with the client id, where to come back to and the state" do
      url = URI.parse(client.authorization_url(redirect_uri: "https://budgiebuddie.com/splitwise/callback", state: "a-random-state"))

      expect(url).to have_attributes(scheme: "https", host: "secure.splitwise.com", path: "/oauth/authorize")
      expect(Rack::Utils.parse_query(url.query)).to eq(
        "response_type" => "code", "client_id" => "the-client-id", "redirect_uri" => "https://budgiebuddie.com/splitwise/callback", "state" => "a-random-state"
      )
    end

    it "never carries the client's secret, which is for the server alone" do
      expect(client.authorization_url(redirect_uri: "https://example.com/cb", state: "s")).not_to include("the-client-secret")
    end
  end

  describe "#exchange_code" do
    it "swaps the code for an access token with a form post to Splitwise's token endpoint, over TLS and with timeouts" do
      answer(200, access_token: "the-access-token", token_type: "bearer")

      token = client.exchange_code(code: "the-code", redirect_uri: "https://example.com/cb")

      expect(token).to eq("the-access-token")
      expect(connections.first).to include(host: "secure.splitwise.com", port: 443, use_ssl: true, open_timeout: be_a(Integer), read_timeout: be_a(Integer))
      request = sent.first
      expect(request).to be_a(Net::HTTP::Post)
      expect(request.path).to eq("/oauth/token")
      expect(request["Content-Type"]).to eq("application/x-www-form-urlencoded")
      expect(Rack::Utils.parse_query(request.body)).to eq(
        "grant_type" => "authorization_code", "code" => "the-code", "redirect_uri" => "https://example.com/cb",
        "client_id" => "the-client-id", "client_secret" => "the-client-secret"
      )
    end

    it "is an error when Splitwise refuses the code, saying so without the code, the secret or what Splitwise answered" do
      answer(400, error: "invalid_grant", error_description: "the-code is no good")

      expect { client.exchange_code(code: "the-code", redirect_uri: "https://example.com/cb") }
        .to raise_error(Splitwise::Error) { |error| expect(error.message).to eq("Splitwise didn't accept the sign-in (400).") }
    end

    it "is an error when the answer has no token in it" do
      answer(200, token_type: "bearer")

      expect { client.exchange_code(code: "c", redirect_uri: "https://example.com/cb") }.to raise_error(Splitwise::Error, "Splitwise sent no token.")
    end

    it "is an error when the answer isn't JSON" do
      answer(200, "<html>nope</html>")

      expect { client.exchange_code(code: "c", redirect_uri: "https://example.com/cb") }.to raise_error(Splitwise::Error, "Splitwise sent no token.")
    end
  end

  describe "#current_user" do
    let(:body) do
      { user: { id: 4321, first_name: "Robert", last_name: "Graham-Hu", email: "robert@example.com", default_currency: "CAD", picture: { medium: "https://example.com/r.png" } } }
    end

    it "asks who the token is for, with the token as a Bearer token and nowhere else, and says who as the Splitwise user's id and name" do
      answer(200, body)

      user = client.current_user("the-access-token")

      expect(user).to eq(Splitwise::Person.new(id: "4321", name: "Robert G."))
      request = sent.first
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq("/api/v3.0/get_current_user")
      expect(request["Authorization"]).to eq("Bearer the-access-token")
    end

    it "names someone by their first name when they have no last name, which Splitwise allows" do
      answer(200, user: { id: 7, first_name: "Robin", last_name: nil })

      expect(client.current_user("t").name).to eq("Robin")
    end

    it "keeps no one's email, only the id and the name" do
      answer(200, body)

      expect(client.current_user("t").to_h.values.join).not_to include("robert@example.com")
    end

    it "is Rejected when Splitwise doesn't accept the token, which is how a token that stopped working looks" do
      answer(401, error: "Invalid API Request: you are not logged in")

      expect { client.current_user("the-access-token") }.to raise_error(Splitwise::Rejected, "Splitwise doesn't accept the token any more.")
    end

    it "is an Error, and not a Rejected, for any other refusal, and says nothing of the token" do
      answer(500, "oops")

      expect { client.current_user("the-access-token") }
        .to raise_error(Splitwise::Error) { |error| expect([ error, error.message ]).to match([ be_an_instance_of(Splitwise::Error), "Splitwise answered 500." ]) }
    end

    it "is an Error when the answer doesn't say who it is" do
      answer(200, user: {})

      expect { client.current_user("t") }.to raise_error(Splitwise::Error, "Splitwise didn't say who signed in.")
    end

    it "is an Error when Splitwise can't be reached, and the error doesn't carry the token" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout)

      expect { client.current_user("the-access-token") }
        .to raise_error(Splitwise::Error) { |error| expect(error.message).to eq("Splitwise couldn't be reached.") }
    end
  end

  it "keeps its secret out of what it shows of itself" do
    expect(client.inspect).not_to include("the-client-secret")
    expect(client.to_s).not_to include("the-client-secret")
  end
end
