require "rails_helper"

# The real client, which specs never otherwise reach: every other spec has PlaidApi.client replaced (spec/support/plaid.rb). Here only Net::HTTP is, so nothing
# leaves the machine, and what's checked is what the client asks Plaid and how it reads the answer.
RSpec.describe PlaidApi::Client do
  subject(:client) { described_class.new(client_id: "the-client-id", secret: "the-secret", environment: "sandbox") }

  # The requests that would have been sent, and the answer Plaid gives to the next one.
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

  def sent_body
    JSON.parse(sent.last.body)
  end

  # Plaid's error shape, on any status that isn't a success.
  def plaid_error(code, display_message: nil)
    { error_type: "INVALID_INPUT", error_code: code, error_message: "the developer's message, never shown", display_message: display_message, request_id: "req-1" }
  end

  describe "#configured?" do
    it "needs the client id, the secret and an environment Budgie knows" do
      expect(described_class.new(client_id: "id", secret: "secret", environment: "sandbox")).to be_configured
      expect(described_class.new(client_id: "id", secret: "secret", environment: "production")).to be_configured
      expect(described_class.new(client_id: "id", secret: "secret", environment: "development")).not_to be_configured
      expect(described_class.new(client_id: "id", secret: "secret", environment: nil)).not_to be_configured
      expect(described_class.new(client_id: "id", secret: "", environment: "sandbox")).not_to be_configured
      expect(described_class.new(client_id: nil, secret: "secret", environment: "sandbox")).not_to be_configured
    end
  end

  describe "the host it asks" do
    it "is Sandbox's or Production's, by the environment, over TLS and with timeouts" do
      answer(200, link_token: "link-sandbox-1")
      client.create_link_token(client_user_id: "7")
      answer(200, link_token: "link-production-1")
      described_class.new(client_id: "id", secret: "secret", environment: "production").create_link_token(client_user_id: "7")

      expect(connections.map { it[:host] }).to eq([ "sandbox.plaid.com", "production.plaid.com" ])
      expect(connections.first).to include(port: 443, use_ssl: true, open_timeout: be_a(Integer), read_timeout: be_a(Integer))
    end
  end

  describe "#create_link_token" do
    it "asks for a token for a new connection with Budgie's settings, the client's id and secret in headers and never in the body" do
      answer(200, link_token: "link-sandbox-abc", expiration: "2026-11-19T20:00:00Z")

      expect(client.create_link_token(client_user_id: "42")).to eq("link-sandbox-abc")

      request = sent.last
      expect(request.path).to eq("/link/token/create")
      expect(request["Content-Type"]).to eq("application/json")
      expect(request["PLAID-CLIENT-ID"]).to eq("the-client-id")
      expect(request["PLAID-SECRET"]).to eq("the-secret")
      expect(sent_body).to eq(
        "client_name" => "Budgie", "language" => "en", "country_codes" => [ "CA" ], "user" => { "client_user_id" => "42" },
        "products" => [ "transactions" ], "transactions" => { "days_requested" => 730 },
        "account_filters" => { "depository" => { "account_subtypes" => [ "all" ] }, "credit" => { "account_subtypes" => [ "all" ] } }
      )
      expect(request.body).not_to include("the-secret")
    end

    it "is an Error when the answer has no token in it" do
      answer(200, request_id: "req-1")

      expect { client.create_link_token(client_user_id: "42") }.to raise_error(PlaidApi::Error, "Plaid sent no link.")
    end
  end

  describe "#exchange_public_token" do
    it "swaps the public token for the Item's access token and id" do
      answer(200, access_token: "access-sandbox-xyz", item_id: "item-1", request_id: "req-1")

      exchange = client.exchange_public_token("public-sandbox-abc")

      expect(exchange).to have_attributes(access_token: "access-sandbox-xyz", item_id: "item-1")
      expect(sent.last.path).to eq("/item/public_token/exchange")
      expect(sent_body).to eq("public_token" => "public-sandbox-abc")
    end

    it "keeps the access token out of what it shows of itself" do
      answer(200, access_token: "access-sandbox-xyz", item_id: "item-1")

      expect(client.exchange_public_token("public-sandbox-abc").inspect).not_to include("access-sandbox-xyz")
    end

    it "is an Error when the answer has no token or Item in it" do
      answer(200, item_id: "item-1")

      expect { client.exchange_public_token("public-sandbox-abc") }.to raise_error(PlaidApi::Error, "Plaid sent no connection.")
    end
  end

  describe "#accounts" do
    let(:answered) do
      { accounts: [
          { account_id: "acc-1", name: "TD Every Day Chequing", official_name: "TD Every Day Chequing Account", mask: "4821", type: "depository", subtype: "checking",
            balances: { available: 1203.45, current: 1210.05, iso_currency_code: "CAD", unofficial_currency_code: nil, limit: nil } },
          { account_id: "acc-2", name: "TD U.S. Dollar", mask: nil, type: "depository", subtype: "savings",
            balances: { current: 0.1, iso_currency_code: "USD" } }
        ],
        item: { item_id: "item-1", institution_id: "ins_42", institution_name: "TD Canada Trust" }, request_id: "req-1" }
    end

    it "asks with the access token in the body, and says each account and the Item it's on" do
      answer(200, answered)

      result = client.accounts("access-sandbox-xyz")

      expect(sent.last.path).to eq("/accounts/get")
      expect(sent_body).to eq("access_token" => "access-sandbox-xyz")
      expect(result).to have_attributes(item_id: "item-1", institution_id: "ins_42", institution_name: "TD Canada Trust")
      expect(result.accounts.first).to have_attributes(
        id: "acc-1", name: "TD Every Day Chequing", mask: "4821", type: "depository", subtype: "checking", iso_currency_code: "CAD", unofficial_currency_code: nil
      )
      expect(result.accounts.second).to have_attributes(id: "acc-2", mask: nil, iso_currency_code: "USD")
    end

    it "reads balances as decimals from the JSON's own text, never through a float" do
      answer(200, '{"accounts":[{"account_id":"a","name":"Chequing","balances":{"current":0.1,"available":12345678901.23,"iso_currency_code":"CAD"}}],"item":{"item_id":"i"}}')

      account = client.accounts("access-sandbox-xyz").accounts.first

      expect(account.current_balance).to be_a(BigDecimal).and eq(BigDecimal("0.1"))
      expect(account.available_balance).to eq(BigDecimal("12345678901.23"))
    end

    it "says whether an account is in a currency, which an unofficial one never is" do
      answer(200, accounts: [
        { account_id: "a", name: "Chequing", balances: { iso_currency_code: "CAD" } },
        { account_id: "b", name: "Bitcoin", balances: { iso_currency_code: nil, unofficial_currency_code: "BTC" } },
        { account_id: "c", name: "Odd", balances: { iso_currency_code: "CAD", unofficial_currency_code: "XYZ" } }
      ], item: { item_id: "i" })

      accounts = client.accounts("access-sandbox-xyz").accounts

      expect(accounts.map { it.in_currency?("CAD") }).to eq([ true, false, false ])
      expect(accounts.map(&:currency)).to eq([ "CAD", "BTC", "XYZ" ])
    end

    it "reads every field as optional, and drops what isn't an account at all" do
      answer(200, accounts: [ { account_id: "a" }, "not an account", { name: "no id" } ], item: nil)

      result = client.accounts("access-sandbox-xyz")

      expect(result.accounts.map(&:id)).to eq([ "a" ])
      expect(result.accounts.first).to have_attributes(name: nil, mask: nil, iso_currency_code: nil, current_balance: nil)
      expect(result).to have_attributes(item_id: nil, institution_id: nil, institution_name: nil)
    end
  end

  describe "#remove_item" do
    it "asks Plaid to remove the Item the access token is for" do
      answer(200, request_id: "req-1")

      client.remove_item("access-sandbox-xyz")

      expect(sent.last.path).to eq("/item/remove")
      expect(sent_body).to eq("access_token" => "access-sandbox-xyz")
    end
  end

  describe "errors" do
    it "carries Plaid's code and its message for a person, and says the message" do
      answer(400, plaid_error("ITEM_LIMIT", display_message: "You've connected as many banks as this app allows."))

      expect { client.exchange_public_token("public-sandbox-abc") }.to raise_error(PlaidApi::Error) { |error|
        expect(error.error_code).to eq("ITEM_LIMIT")
        expect(error.display_message).to eq("You've connected as many banks as this app allows.")
        expect(error.message).to eq("You've connected as many banks as this app allows.")
      }
    end

    it "says the code when Plaid gives no message for a person, and never the developer's message" do
      answer(400, plaid_error("INVALID_PUBLIC_TOKEN"))

      expect { client.exchange_public_token("public-sandbox-abc") }.to raise_error(PlaidApi::Error) { |error|
        expect(error.error_code).to eq("INVALID_PUBLIC_TOKEN")
        expect(error.display_message).to be_nil
        expect(error.message).to eq("Plaid refused it (INVALID_PUBLIC_TOKEN).")
        expect(error.message).not_to include("developer")
      }
    end

    it "says the status for an answer that isn't Plaid's, and never a token, the secret or the body" do
      answer(502, "<html>Bad gateway, access-sandbox-xyz</html>")

      expect { client.accounts("access-sandbox-xyz") }.to raise_error(PlaidApi::Error) { |error|
        expect(error.message).to eq("Plaid answered 502.")
        expect(error.error_code).to be_nil
        expect(error.full_message).not_to include("access-sandbox-xyz", "the-secret", "Bad gateway")
      }
    end

    it "is an Error when Plaid can't be reached" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)

      expect { client.remove_item("access-sandbox-xyz") }.to raise_error(PlaidApi::Error, "Plaid couldn't be reached.")
    end

    it "is an Error when a success isn't JSON" do
      answer(200, "not json")

      expect { client.create_link_token(client_user_id: "1") }.to raise_error(PlaidApi::Error, "Plaid sent no link.")
    end
  end

  it "keeps its secret out of what it shows of itself" do
    expect(client.inspect).not_to include("the-secret", "the-client-id")
    expect(client.to_s).not_to include("the-secret")
  end
end
