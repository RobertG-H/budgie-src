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

  describe "#expenses" do
    # What get_expenses answers, as Splitwise does: money as decimal strings, UTC timestamps, a share for each person, and fields Budgie doesn't read.
    def expense_body(id: 1001, **overrides)
      { id: id, group_id: 0, description: "Dinner at Nonna's", details: "notes", cost: "100.00", currency_code: "CAD", payment: false, date: "2026-10-03T00:00:00Z",
        created_at: "2026-10-03T21:10:00Z", updated_at: "2026-10-04T09:30:00Z", deleted_at: nil, category: { id: 13, name: "Dining out" },
        repayments: [ { from: 8, to: 4321, amount: "50.00" } ],
        users: [ { user_id: 4321, user: { id: 4321, first_name: "Robert" }, paid_share: "100.00", owed_share: "50.00", net_balance: "50.00" },
                 { user_id: 8, user: { id: 8, first_name: "Jane" }, paid_share: "0.00", owed_share: "50.00", net_balance: "-50.00" } ] }.merge(overrides)
    end

    def read(**options)
      client.expenses("the-access-token", user_id: "4321", limit: 100, offset: 0, **options)
    end

    it "asks for a page with the token as a Bearer token, the limit and offset set, and only the dates it's given" do
      answer(200, expenses: [])

      read(updated_after: Time.utc(2026, 10, 4, 9, 25), dated_after: Time.utc(2026, 9, 30))

      request = sent.first
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to start_with("/api/v3.0/get_expenses?")
      expect(request["Authorization"]).to eq("Bearer the-access-token")
      expect(Rack::Utils.parse_query(URI.parse(request.path).query)).to eq(
        "limit" => "100", "offset" => "0", "updated_after" => "2026-10-04T09:25:00Z", "dated_after" => "2026-09-30T00:00:00Z"
      )
    end

    it "leaves out the dates it isn't given" do
      answer(200, expenses: [])

      read

      expect(Rack::Utils.parse_query(URI.parse(sent.first.path).query).keys).to contain_exactly("limit", "offset")
    end

    it "says each expense as only what Budgie reads, with the person's own net share and not anyone else's" do
      answer(200, expenses: [ expense_body ])

      expense = read.sole

      expect(expense).to eq(
        Splitwise::Expense.new(id: "1001", description: "Dinner at Nonna's", date: Date.new(2026, 10, 3), currency_code: "CAD", payment: false,
          updated_at: Time.utc(2026, 10, 4, 9, 30), deleted_at: nil, net_balance: BigDecimal("50.00"))
      )
    end

    it "reads money as a decimal and never a float, and the sign as Splitwise gives it" do
      answer(200, expenses: [ expense_body(users: [ { user_id: 4321, net_balance: "-0.10" } ]) ])

      expect(read.sole.net_balance).to eq(BigDecimal("-0.10"))
      expect(read.sole.net_balance).to be_a(BigDecimal)
    end

    it "takes the person's share by the id on the user as well, since Splitwise sends it both ways" do
      answer(200, expenses: [ expense_body(users: [ { user: { id: 4321 }, net_balance: "12.34" } ]) ])

      expect(read.sole.net_balance).to eq(BigDecimal("12.34"))
    end

    it "has no net share for an expense the person isn't part of" do
      answer(200, expenses: [ expense_body(users: [ { user_id: 8, net_balance: "-50.00" } ]) ])

      expect(read.sole.net_balance).to be_nil
    end

    it "keeps the date as the UTC date it's sent as, at either end of a month, whatever it would be in another time zone" do
      answer(200, expenses: [
        expense_body(id: 1, date: "2026-10-31T00:00:00Z"), expense_body(id: 2, date: "2026-11-01T00:00:00Z"), expense_body(id: 3, date: "2026-10-31T23:59:59Z")
      ])

      expect(read.map(&:date)).to eq([ Date.new(2026, 10, 31), Date.new(2026, 11, 1), Date.new(2026, 10, 31) ])
    end

    it "says a payment, which is a settle-up, and a deleted expense, which Splitwise leaves in the listing" do
      answer(200, expenses: [ expense_body(payment: true, deleted_at: "2026-10-05T12:00:00Z") ])

      expect(read.sole).to have_attributes(payment: true, deleted_at: Time.utc(2026, 10, 5, 12), deleted?: true)
    end

    it "reads every field as optional and ignores keys it doesn't know" do
      answer(200, expenses: [ { id: 7, mystery: { nested: true } }, { id: 8, description: nil, date: "not a date", updated_at: 5, users: "nope", payment: nil } ])

      first, second = read

      expect(first).to eq(Splitwise::Expense.new(id: "7", description: nil, date: nil, currency_code: nil, payment: false, updated_at: nil, deleted_at: nil, net_balance: nil))
      expect(second).to have_attributes(id: "8", description: nil, date: nil, payment: false, updated_at: nil, net_balance: nil)
    end

    it "keeps an expense with no id, so a page is as long as Splitwise made it, and drops what isn't an expense at all" do
      answer(200, expenses: [ { description: "No id" }, expense_body(id: 9), "nonsense", nil ])

      expect(read.map(&:id)).to eq([ nil, "9" ])
    end

    it "is no expenses when the answer has none, or isn't what it should be" do
      answer(200, expenses: "nope")
      expect(read).to eq([])

      answer(200, "<html>proxy error</html>")
      expect(read).to eq([])
    end

    it "is Rejected for a 401, in either of Splitwise's error shapes, and says nothing of what Splitwise answered" do
      [ { error: "Invalid API Request: you are not logged in" }, { errors: { base: [ "not logged in" ] } } ].each do |body|
        answer(401, body)

        expect { read }.to raise_error(Splitwise::Rejected) { |error| expect(error.message).to eq("Splitwise doesn't accept the token any more.") }
      end
    end

    it "is RateLimited for a 429, which is something to try again later and not a broken sign-in" do
      answer(429, "slow down")

      expect { read }.to raise_error(Splitwise::RateLimited, "Splitwise is limiting how often Budgie can ask.")
      expect(Splitwise::RateLimited.ancestors).to include(Splitwise::Error)
      expect(Splitwise::RateLimited.ancestors).not_to include(Splitwise::Rejected)
    end

    it "treats a 403 and a 404 as not found or not allowed, since Splitwise uses either for both" do
      [ 403, 404 ].each do |status|
        answer(status, errors: { base: [ "record not found" ] })

        expect { read }.to raise_error(Splitwise::Error) { |error|
          expect([ error.class, error.message ]).to eq([ Splitwise::Error, "Splitwise says what Budgie asked for wasn't found, or isn't allowed (#{status})." ])
        }
      end
    end

    it "is an Error for any other failure, in words that carry neither the token nor the body" do
      answer(500, "the-access-token blew up")

      expect { read }.to raise_error(Splitwise::Error) { |error| expect(error.message).to eq("Splitwise answered 500.") }
    end

    it "is an Error for a 200 that has an error in it, in either shape, since Splitwise sometimes fails that way" do
      [ { error: "something went wrong" }, { errors: { base: [ "something went wrong" ] } } ].each do |body|
        answer(200, body.merge(expenses: [ expense_body ]))

        expect { read }.to raise_error(Splitwise::Error) { |error| expect(error.message).to eq("Splitwise answered with an error.") }
      end
    end

    it "is not an error for an empty errors object, which is how Splitwise says there were none" do
      answer(200, errors: {}, expenses: [ expense_body ])

      expect(read.size).to eq(1)
    end

    it "is an Error when Splitwise can't be reached" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)

      expect { read }.to raise_error(Splitwise::Error, "Splitwise couldn't be reached.")
    end
  end

  it "keeps its secret out of what it shows of itself" do
    expect(client.inspect).not_to include("the-client-secret")
    expect(client.to_s).not_to include("the-client-secret")
  end
end
