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

  # The choices as the controller permits them from the page, by the account's place in the list.
  def choices(rows = { "0" => { becomes: "new", name: "Chequing", read_from: "2026-10-01" }, "1" => { becomes: "leave" } })
    ConnectPlaid.choices(budget, link, ActionController::Parameters.new(rows).permit!)
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

    it "reads the bank's first word up to a hyphen or space, so an account named for it isn't named twice, and a longer word isn't taken for it" do
      tartan = PendingPlaidLink.new(public_token: "p", institution_id: "ins_43", institution_name: "Tartan-Dominion Bank of Canada", accounts: [], linked_at: linked_at, budget_id: budget.id)
      named = ->(name) { described_class.default_name(tartan, PendingPlaidLink::SharedAccount.new(id: "a", name: name, mask: nil, subtype: nil)) }

      expect(named.("Tartan U.S. Dollar")).to eq("Tartan U.S. Dollar")
      expect(named.("tartan-dominion chequing")).to eq("tartan-dominion chequing")
      expect(named.("Plaid Checking")).to eq("Tartan-Dominion Bank of Canada Plaid Checking")
      expect(named.("Tartanic Savings")).to eq("Tartan-Dominion Bank of Canada Tartanic Savings")
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

    it "are only a new Account, an Account it can link onto, or left out" do
      result = connect(choices("0" => { becomes: "link:5" }, "1" => { becomes: "other" }))

      expect(result).to be_invalid
      expect(result.choices.map { it.errors[:becomes] }).to all(eq([ "isn't one of the choices" ]))
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

    it "reads a stored name as it reads the one Link sent, so spaces Plaid's answer has don't hide the overlap" do
      create(:budget_account, :plaid, budget: budget, bank_connection: existing, external_name: "TD  ePremium   Savings ", external_mask: "1100")

      expect(connect).to be_refused
      expect(plaid.exchanges).to be_empty
    end

    it "takes a missing mask to equal only another missing mask" do
      link.accounts[0] = link.accounts[0].with(mask: nil)
      with_a_mask = create(:budget_account, :plaid, budget: budget, bank_connection: existing, external_name: "TD Every Day Chequing", external_mask: "4821")
      expect(described_class.new(budget: budget, link: link, choices: choices).send(:already_connected_account)).to be_nil

      with_a_mask.update!(external_mask: nil)
      expect(connect).to be_refused
    end

    it "isn't a reason to refuse a connection that was disconnected, whose overlapping Account starts on Link onto instead" do
      old_chequing = create(:budget_account, :plaid, budget: budget, bank_connection: existing, external_name: "TD Every Day Chequing", external_mask: "4821")
      existing.disconnect!

      expect(described_class.choices(budget, link).first.becomes).to eq("link:#{old_chequing.id}")
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

    it "removes the Item and raises when something else goes wrong after the exchange, so no Item is left at Plaid" do
      allow(budget).to receive(:with_lock).and_raise(ActiveRecord::LockWaitTimeout)

      expect { connect }.to raise_error(ActiveRecord::LockWaitTimeout)
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

  describe "linking onto an existing Account" do
    let!(:csv_chequing) { create(:budget_account, budget: budget, name: "Chequing", default_csv_format: create(:budget_csv_format, budget: budget)) }

    def link_choices(account, read_from: "2026-11-10", other: { becomes: "leave" })
      choices("0" => { becomes: "link:#{account.id}", link_read_from: read_from }, "1" => other)
    end

    describe ".choices" do
      it "offers each Account that takes CSV Imports and each of a disconnected bank's Accounts, by name, and none of a live connection's or Splitwise's" do
        disconnected = create(:budget_bank_connection, :plaid, budget: budget)
        old_visa = create(:budget_account, :plaid, budget: budget, bank_connection: disconnected, name: "Old Visa")
        disconnected.disconnect!
        create(:budget_account, :plaid, budget: budget, name: "Live Savings")
        create(:budget_account, :synced, budget: budget, name: "Splitwise")
        create(:budget_account, budget: create(:budget), name: "Another budget's")
        importable = create(:budget_account, budget: budget, name: "amex")

        targets = described_class.choices(budget, link).first.targets

        expect(targets.map(&:name)).to eq([ "amex", "Chequing", "Old Visa" ])
        expect(targets.map(&:id)).to eq([ importable.id, csv_chequing.id, old_visa.id ])
      end

      it "starts a target's date at its latest bank transaction's, that day included, or where a new Account would start when it has none" do
        create(:budget_bank_transaction, account: csv_chequing, date: Date.new(2026, 11, 10))
        create(:budget_bank_transaction, account: csv_chequing, date: Date.new(2026, 9, 2))
        empty = create(:budget_account, budget: budget, name: "Empty")

        targets = described_class.choices(budget, link).first.targets.index_by(&:name)

        expect(targets.fetch("Chequing").read_from).to eq(Date.new(2026, 11, 10))
        expect(targets.fetch("Empty").read_from).to eq(Date.new(2026, 9, 2))
        expect(empty).not_to be_synced
      end

      it "keeps the date sent for a linked row, and starts it at the Account's own date when none was" do
        create(:budget_bank_transaction, account: csv_chequing, date: Date.new(2026, 11, 10))

        sent = choices("0" => { becomes: "link:#{csv_chequing.id}", link_read_from: "2026-11-01" }, "1" => { becomes: "link:#{csv_chequing.id}" })

        expect(sent.first).to have_attributes(link_target: have_attributes(id: csv_chequing.id), link_read_from: Date.new(2026, 11, 1))
        expect(sent.second.link_read_from).to eq(Date.new(2026, 11, 10))
      end
    end

    it "gives the Account the connection, Plaid's id, name and mask and the date, clears its Default CSV format, and keeps the rest of it", :aggregate_failures do
      csv_chequing.update!(files_with_rules: false)
      kept = create(:budget_bank_transaction, account: csv_chequing, date: Date.new(2026, 11, 10))
      rule = create(:budget_filing_rule, budget: budget, account: csv_chequing)

      result = connect(link_choices(csv_chequing))

      expect(result).to be_connected
      expect(csv_chequing.reload).to have_attributes(name: "Chequing", bank_connection: budget.bank_connections.sole, external_account_id: "acc-1",
        external_name: "TD Every Day Chequing", external_mask: "4821", read_from: Date.new(2026, 11, 10), default_csv_format: nil, files_with_rules: false)
      expect(csv_chequing).to be_synced
      expect(csv_chequing.bank_transactions).to eq([ kept ])
      expect(rule.reload.account).to eq(csv_chequing)
      expect(result.accounts).to eq([ csv_chequing ])
      expect(result.notice).to eq("Connected TD Canada Trust. Its bank transactions arrive within the hour. Chequing keeps its bank transactions and is synced from it now.")
    end

    it "lists the Accounts it made and linked in the page's order" do
      result = connect(link_choices(csv_chequing, other: { becomes: "new", name: "Savings", read_from: "2026-10-01" }))

      expect(result.accounts.map(&:name)).to eq([ "Chequing", "Savings" ])
      expect(budget.bank_connections.sole.accounts.count).to eq(2)
    end

    it "takes no CSV Import once it's linked" do
      connect(link_choices(csv_chequing))

      import = Budget::Import.new(account: csv_chequing.reload, csv_format: create(:budget_csv_format, budget: budget, name: "Other"), file_name: "x.csv")
      expect(import).not_to be_valid
      expect(budget.accounts.importable).not_to include(csv_chequing)
    end

    it "moves an Account of a disconnected connection onto the new one, shares it again, and deletes the old connection once it has no Accounts" do
      old = create(:budget_bank_connection, :plaid, budget: budget)
      old_chequing = create(:budget_account, :plaid, budget: budget, bank_connection: old, name: "Old chequing", unshared_at: 1.day.ago)
      old_savings = create(:budget_account, :plaid, budget: budget, bank_connection: old, name: "Old savings")
      old.disconnect!

      connect(link_choices(old_chequing))

      expect(old_chequing.reload).to have_attributes(bank_connection: budget.bank_connections.find_by!(login_id: "item-1"), external_account_id: "acc-1", unshared_at: nil)
      expect(old.reload.accounts).to eq([ old_savings ])

      plaid.links("public-2", item_id: "item-2", institution_id: "ins_42", institution_name: "TD Canada Trust", accounts: [ plaid.account("acc-9", "TD ePremium Savings") ])
      second = PendingPlaidLink.new(public_token: "public-2", institution_id: "ins_42", institution_name: "TD Canada Trust", linked_at: Time.current, budget_id: budget.id,
        accounts: [ PendingPlaidLink::SharedAccount.new(id: "acc-9", name: "TD ePremium Savings", mask: nil, subtype: nil) ])
      described_class.call(budget: budget, link: second,
        choices: described_class.choices(budget, second, ActionController::Parameters.new("0" => { becomes: "link:#{old_savings.id}", link_read_from: "2026-11-01" }).permit!))

      expect(Budget::BankConnection.exists?(old.id)).to be(false)
      expect(budget.bank_connections.count).to eq(2)
    end

    it "connects with only linked Accounts, which count as connecting one" do
      expect(connect(link_choices(csv_chequing))).to be_connected
    end

    it "refuses the same Account on two rows, on the second" do
      result = connect(choices("0" => { becomes: "link:#{csv_chequing.id}", link_read_from: "2026-11-10" },
                               "1" => { becomes: "link:#{csv_chequing.id}", link_read_from: "2026-11-10" }))

      expect(result).to be_invalid
      expect(result.choices.first.errors).to be_empty
      expect(result.choices.second.errors[:becomes]).to eq([ "is already chosen for another account on this page" ])
      expect(plaid.exchanges).to be_empty
    end

    it "refuses an Account it can't link onto, such as a live connection's or another budget's" do
      live = create(:budget_account, :plaid, budget: budget)
      elsewhere = create(:budget_account, budget: create(:budget))

      result = connect(choices("0" => { becomes: "link:#{live.id}" }, "1" => { becomes: "link:#{elsewhere.id}" }))

      expect(result.choices.map { it.errors[:becomes] }).to all(eq([ "isn't one of the choices" ]))
      expect(plaid.exchanges).to be_empty
    end

    it "needs a date that could be real, said on the linked row" do
      result = connect(link_choices(csv_chequing, read_from: "1980-01-01"))

      expect(result).to be_invalid
      expect(result.choices.first.errors[:link_read_from]).to eq([ "can't be before 1990" ])
      expect(connect(link_choices(csv_chequing, read_from: "")).choices.first.errors[:link_read_from]).to eq([ "can't be blank" ])
    end

    it "refuses, removing the Item, when the Account became one it can't link onto since the page was checked" do
      allow(plaid).to receive(:accounts).and_wrap_original do |original, *args|
        create(:budget_account, :plaid, budget: budget).bank_connection.tap { csv_chequing.update_columns(bank_connection_id: it.id, external_account_id: "x", read_from: Date.current) }
        original.call(*args)
      end

      result = connect(link_choices(csv_chequing))

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was connected, since Chequing can't be linked onto any more. Connect again to choose.")
      expect(plaid.removals).to eq([ "access-for-public-1" ])
      expect(budget.bank_connections.where(login_id: "item-1")).to be_empty
    end

    it "brings the Account's latest day in again on the first sync, unfiled, and nothing from before it", :aggregate_failures do
      filed = create(:budget_bank_transaction, :filed, account: csv_chequing, date: Date.new(2026, 11, 10), amount: -82.45, description: "LOBLAWS #1234")
      connect(link_choices(csv_chequing))
      connection = budget.bank_connections.sole
      plaid.adds(connection.access_token,
        plaid.transaction("tx-1", account: "acc-1", amount: "82.45", description: "LOBLAWS #1234", date: "2026-11-10"),
        plaid.transaction("tx-2", account: "acc-1", amount: "12.00", description: "COFFEE", date: "2026-11-09"))

      result = SyncPlaid.call(connection)

      expect(result.created).to eq(1)
      expect(csv_chequing.bank_transactions.order(:id).map { [ it.date, it.external_id ] }).to eq([ [ Date.new(2026, 11, 10), nil ], [ Date.new(2026, 11, 10), "tx-1" ] ])
      expect(csv_chequing.bank_transactions.unfiled.sole.external_id).to eq("tx-1")
      expect(filed.reload).to be_filed
    end
  end
end
