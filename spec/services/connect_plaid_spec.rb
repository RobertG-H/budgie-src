require "rails_helper"

# Connecting a bank once the person has chosen what each account they shared in Plaid Link becomes (ADR 0018). The checks run in order, and everything before
# the exchange spends no Item: the deadline, the choices, the duplicate check, then the exchange, then `/accounts/get` (the ids and the currency), then one
# database transaction. Nothing is kept unless it all works, and an Item that was made is removed when nothing would come of it.
RSpec.describe ConnectPlaid do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:linked_at) { Time.current }
  let(:shared) do
    [ PendingPlaidLink::SharedAccount.new(id: "acc-1", name: "TD Every Day Chequing", mask: "4821", subtype: "checking"),
      PendingPlaidLink::SharedAccount.new(id: "acc-2", name: "TD ePremium Savings", mask: "1100", subtype: "savings") ]
  end
  let(:link) do
    PendingPlaidLink.new(public_token: "public-1", institution_id: "ins_42", institution_name: "TD Canada Trust", accounts: shared, linked_at: linked_at, budget_id: budget.id)
  end

  before do
    plaid.links("public-1", item_id: "item-1", institution_id: "ins_42", institution_name: "TD Canada Trust", accounts: [
      plaid.account("acc-1", "TD Every Day Chequing", mask: "4821", subtype: "checking"),
      plaid.account("acc-2", "TD ePremium Savings", mask: "1100", subtype: "savings")
    ])
  end

  # The choices as the page sends them, by the account's place in the list.
  def choices(rows = { "0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "leave" } })
    ConnectPlaid.choices(budget, link, ActionController::Parameters.new(rows))
  end

  def connect(given = choices)
    described_class.call(budget: budget, link: link, choices: given)
  end

  describe ".choices" do
    it "starts each account as a new Account, named for the bank and the account, reading from where the budget's bank transactions start" do
      create(:budget_bank_transaction, account: create(:budget_account, budget: budget), date: Date.new(2026, 8, 3))
      link.accounts << PendingPlaidLink::SharedAccount.new(id: "acc-3", name: "Visa Infinite", mask: nil, subtype: "credit card")

      started = described_class.choices(budget, link)

      expect(started.map(&:becomes)).to eq([ "new", "new", "new" ])
      expect(started.map(&:name)).to eq([ "TD Every Day Chequing", "TD ePremium Savings", "TD Canada Trust Visa Infinite" ])
      expect(started.map(&:read_from)).to all(eq(Date.new(2026, 8, 3)))
    end

    it "keeps what was sent, by each account's place, and nothing for an account that wasn't sent" do
      kept = choices("0" => { becomes: "leave", name: "Kept", read_from: "2026-09-01" })

      expect(kept.first).to have_attributes(becomes: "leave", name: "Kept", read_from: Date.new(2026, 9, 1))
      expect(kept.second).to have_attributes(becomes: "new", name: "TD ePremium Savings")
    end
  end

  describe "connecting" do
    it "makes the connection and an Account for each account that becomes one, with what Plaid said about them, in one go" do
      result = connect(choices("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "new", name: "Savings", read_from: "2026-09-15" }))

      expect(result).to be_connected
      connection = budget.bank_connections.sole
      expect(connection).to have_attributes(provider: "plaid", login_id: "item-1", login_name: "TD Canada Trust", institution_id: "ins_42", access_token: "access-for-public-1")
      expect(connection.accounts.order(:id)).to match([
        have_attributes(name: "Chequing", read_from: Date.new(2026, 10, 1), external_account_id: "acc-1", external_name: "TD Every Day Chequing", external_mask: "4821", files_with_rules: true),
        have_attributes(name: "Savings", read_from: Date.new(2026, 9, 15), external_account_id: "acc-2", external_name: "TD ePremium Savings", external_mask: "1100", files_with_rules: true)
      ])
      expect(result.accounts.map(&:name)).to eq([ "Chequing", "Savings" ])
      expect(result.notice).to eq("Connected TD Canada Trust. Its bank transactions arrive within the hour.")
      expect(plaid.exchanges).to eq([ "public-1" ])
      expect(plaid.removals).to be_empty
    end

    it "keeps no Account for an account that's left out" do
      result = connect

      expect(result).to be_connected
      expect(budget.accounts.pluck(:external_account_id)).to eq([ "acc-1" ])
    end

    it "stores Plaid's own name and mask for the account, and never what the browser sent" do
      link.accounts[0] = link.accounts[0].with(name: "Something else", mask: "9999")

      connect

      expect(budget.accounts.sole).to have_attributes(external_name: "TD Every Day Chequing", external_mask: "4821")
    end
  end

  describe "the deadline, which is checked first" do
    let(:linked_at) { 31.minutes.ago }

    it "keeps nothing and exchanges nothing once 30 minutes have passed since Link finished" do
      result = connect

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was connected, since the accounts weren't chosen within 30 minutes. Connect again to choose them.")
      expect(plaid.exchanges).to be_empty
      expect(Budget::BankConnection.count).to eq(0)
    end
  end

  describe "the choices" do
    it "need at least one account to become an Account, and nothing is exchanged" do
      result = connect(choices("0" => { becomes: "leave" }, "1" => { becomes: "leave" }))

      expect(result).to be_invalid
      expect(result.error).to eq("Choose at least one account to connect.")
      expect(plaid.exchanges).to be_empty
    end

    it "need a name that isn't another Account's and a date that could be real, said on the choice, and nothing is exchanged" do
      create(:budget_account, budget: budget, name: "Chequing")

      result = connect(choices("0" => { becomes: "new", name: "chequing", read_from: "2026-10-01" }, "1" => { becomes: "new", name: "Savings", read_from: "1980-01-01" }))

      expect(result).to be_invalid
      expect(result.choices.first.errors[:name]).to eq([ "has already been taken" ])
      expect(result.choices.second.errors[:read_from]).to eq([ "can't be before 1990" ])
      expect(result.choices.map(&:name)).to eq([ "chequing", "Savings" ])
      expect(plaid.exchanges).to be_empty
    end

    it "need a name and a date" do
      result = connect(choices("0" => { becomes: "new", name: " ", read_from: "" }))

      expect(result.choices.first.errors[:name]).to eq([ "can't be blank" ])
      expect(result.choices.first.errors[:read_from]).to eq([ "can't be blank" ])
    end

    it "can't give two new Accounts the same name" do
      result = connect(choices("0" => { becomes: "new", name: "Bank", read_from: "2026-10-01" }, "1" => { becomes: "new", name: "bank", read_from: "2026-10-01" }))

      expect(result).to be_invalid
      expect(result.choices.second.errors[:name]).to eq([ "is the same as another account's on this page" ])
    end

    it "are only a new Account or left out" do
      result = connect(choices("0" => { becomes: "link:5" }))

      expect(result).to be_invalid
      expect(result.choices.first.errors[:becomes]).to eq([ "isn't one of the choices" ])
    end

    it "don't look at the name or date of an account that's left out" do
      result = connect(choices("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "leave", name: "", read_from: "nope" }))

      expect(result).to be_connected
    end
  end

  describe "the check for a bank that's already connected" do
    let!(:existing) { create(:budget_bank_connection, :plaid, budget: budget, institution_id: "ins_42", login_name: "TD Canada Trust") }

    it "refuses an account the budget already syncs from a connection that's live, before exchanging, and says which Account to go to" do
      create(:budget_account, :plaid, budget: budget, bank_connection: existing, name: "Old chequing", external_name: "TD ePremium Savings", external_mask: "1100")

      result = connect

      expect(result).to be_refused
      expect(result.alert).to eq("TD Canada Trust is already connected, so nothing new was connected. " \
        "To sync more of its accounts, or if it stopped syncing, use Choose accounts or Reconnect on Old chequing.")
      expect(plaid.exchanges).to be_empty
      expect(budget.bank_connections.count).to eq(1)
    end

    it "lets a second login at the same bank connect, when none of its accounts is one the budget has" do
      create(:budget_account, :plaid, budget: budget, bank_connection: existing, external_name: "TD Every Day Chequing", external_mask: "7777")

      expect(connect).to be_connected
      expect(budget.bank_connections.count).to eq(2)
    end

    it "is about the same bank only" do
      other_bank = create(:budget_bank_connection, :plaid, budget: budget, institution_id: "ins_37", login_name: "CIBC")
      create(:budget_account, :plaid, budget: budget, bank_connection: other_bank, external_name: "TD Every Day Chequing", external_mask: "4821")

      expect(connect).to be_connected
    end

    it "takes a missing mask to equal only another missing mask" do
      link.accounts[0] = link.accounts[0].with(mask: nil)
      with_a_mask = create(:budget_account, :plaid, budget: budget, bank_connection: existing, external_name: "TD Every Day Chequing", external_mask: "4821")
      expect(described_class.new(budget: budget, link: link, choices: choices).send(:already_connected_account)).to be_nil

      with_a_mask.update!(external_mask: nil)
      expect(connect).to be_refused
    end

    it "leaves a connection that was disconnected to later, and connects" do
      create(:budget_account, :plaid, budget: budget, bank_connection: existing, external_name: "TD Every Day Chequing", external_mask: "4821")
      existing.disconnect!

      expect(connect).to be_connected
    end
  end

  describe "the exchange" do
    it "is refused in Plaid's own words, keeping nothing" do
      plaid.fails(:exchange_public_token, PlaidApi::Error.new(error_code: "ITEM_LIMIT", display_message: "This app can't connect any more banks."))

      result = connect

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was connected. This app can't connect any more banks.")
      expect(Budget::BankConnection.count).to eq(0)
      expect(plaid.removals).to be_empty
    end

    it "says Plaid's code when it gives no words" do
      plaid.fails(:exchange_public_token, PlaidApi::Error.new(error_code: "INVALID_PUBLIC_TOKEN"))

      expect(connect.alert).to eq("Nothing was connected. Plaid refused it (INVALID_PUBLIC_TOKEN).")
    end
  end

  describe "what Plaid says the accounts are" do
    it "refuses the whole connect when an account chosen isn't one Plaid has, as a crafted request, and removes the Item" do
      link.accounts[0] = link.accounts[0].with(id: "acc-made-up")

      result = connect

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was connected, since the accounts chosen weren't the ones TD Canada Trust shared. Connect again to choose them.")
      expect(plaid.removals).to eq([ "access-for-public-1" ])
      expect(Budget::BankConnection.count).to eq(0)
      expect(Budget::Account.count).to eq(0)
    end

    it "leaves out an account in another currency, even when it was chosen, and says so" do
      plaid.links("public-1", item_id: "item-1", accounts: [
        plaid.account("acc-1", "TD Every Day Chequing", mask: "4821"),
        plaid.account("acc-2", "TD U.S. Dollar Account", mask: "1100", currency: "USD")
      ])

      result = connect(choices("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "new", name: "US", read_from: "2026-10-01" }))

      expect(result).to be_connected
      expect(budget.accounts.pluck(:name)).to eq([ "Chequing" ])
      expect(result.notice).to eq("Connected TD Canada Trust. Its bank transactions arrive within the hour. TD U.S. Dollar Account was left out: it's in USD.")
    end

    it "leaves out an account with an unofficial currency" do
      plaid.links("public-1", item_id: "item-1", accounts: [
        plaid.account("acc-1", "TD Every Day Chequing", mask: "4821"),
        plaid.account("acc-2", "Points", mask: "1100", currency: nil, unofficial_currency: "PTS")
      ])

      result = connect(choices("0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "new", name: "Points", read_from: "2026-10-01" }))

      expect(result.notice).to end_with("Points was left out: it's in PTS.")
    end

    it "removes the Item and keeps nothing when every account chosen is in another currency" do
      plaid.links("public-1", item_id: "item-1", accounts: [ plaid.account("acc-1", "TD U.S. Dollar Account", mask: "4821", currency: "USD") ])

      result = connect

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was connected, since every account chosen is in another currency.")
      expect(plaid.removals).to eq([ "access-for-public-1" ])
      expect(Budget::BankConnection.count).to eq(0)
    end

    it "removes the Item and keeps nothing when Plaid can't say" do
      plaid.fails(:accounts, PlaidApi::Error.new("Plaid couldn't be reached."))

      result = connect

      expect(result.alert).to eq("Nothing was connected. Plaid couldn't be reached.")
      expect(plaid.removals).to eq([ "access-for-public-1" ])
      expect(Budget::BankConnection.count).to eq(0)
    end
  end

  describe "saving" do
    it "removes the Item and keeps nothing when an Account can't be saved after all, such as a name taken a moment ago" do
      # Another request takes the name while Plaid is being asked, after the choices were checked.
      allow(plaid).to receive(:accounts).and_wrap_original do |original, *args|
        create(:budget_account, budget: budget, name: "Chequing")
        original.call(*args)
      end

      result = connect

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was connected. Name has already been taken.")
      expect(plaid.removals).to eq([ "access-for-public-1" ])
      expect(Budget::BankConnection.count).to eq(0)
    end

    it "still refuses when removing the Item fails, and says nothing of the token in the log" do
      plaid.links("public-1", item_id: "item-1", accounts: [ plaid.account("acc-1", "TD U.S. Dollar Account", currency: "USD") ])
      plaid.fails(:remove_item, PlaidApi::Error.new("Plaid couldn't be reached."))
      logged = []
      allow(Rails.logger).to receive(:error) { |message| logged << message }

      expect(connect).to be_refused
      expect(logged).to contain_exactly(a_string_including("item-1"))
      expect(logged.join).not_to include("access-for-public-1")
    end
  end
end
