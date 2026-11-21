require "rails_helper"

# A sync brings each posted transaction of a bank connected through Plaid into the Account it's for, as a bank transaction, and keeps it up to date as the bank
# changes or removes it (ADR 0018). It never changes a record that was filed from one. Specs never reach Plaid: PlaidFake keeps each Item's changes and answers a
# page of them at a time, as `/transactions/sync` does.
RSpec.describe SyncPlaid do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:connection) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust", access_token: "its-token") }
  let!(:chequing) do
    create(:budget_account, :plaid, budget: budget, name: "TD Chequing", bank_connection: connection, external_account_id: "acc-1", read_from: Date.new(2026, 10, 1))
  end
  let!(:visa) do
    create(:budget_account, :plaid, budget: budget, name: "TD Visa", bank_connection: connection, external_account_id: "acc-2", read_from: Date.new(2026, 9, 1))
  end

  def sync
    described_class.call(connection)
  end

  def tx(id, account: "acc-1", **attributes)
    plaid.transaction(id, account: account, **attributes)
  end

  def adds(*transactions)
    plaid.adds("its-token", *transactions)
  end

  def modifies(*transactions)
    plaid.modifies("its-token", *transactions)
  end

  def removes(*ids, account: "acc-1")
    plaid.removes("its-token", *ids, account: account)
  end

  def bank_transactions
    Budget::BankTransaction.where(account: [ chequing, visa ]).order(:id)
  end

  def bank_transaction(external_id)
    Budget::BankTransaction.find_by!(account: [ chequing, visa ], external_id: external_id)
  end

  describe "bringing transactions in" do
    it "makes a bank transaction of each posted one in the Account it's for, signed as Budgie signs it, from the bank's own description", :aggregate_failures do
      adds tx("tx-1", amount: "82.45", date: "2026-10-03", authorized_date: "2026-10-01", description: "LOBLAWS #1234 TORONTO"),
        tx("tx-2", account: "acc-2", amount: "-500.00", date: "2026-10-05", description: "PAYMENT - THANK YOU")

      result = sync

      expect(result).to be_success
      expect(bank_transaction("tx-1")).to have_attributes(account: chequing, amount: BigDecimal("-82.45"), date: Date.new(2026, 10, 3),
        authorized_date: Date.new(2026, 10, 1), description: "LOBLAWS #1234 TORONTO", import: nil, ignored_at: nil, removed_at: nil)
      expect(bank_transaction("tx-2")).to have_attributes(account: visa, amount: BigDecimal("500.00"), authorized_date: nil, description: "PAYMENT - THANK YOU")
      expect(bank_transactions).to all(be_unfiled)
      expect(result).to have_attributes(created: 2, changed: 0, removed: 0, skipped: 0, filed_by_rules: 0, ignored_by_rules: 0)
    end

    it "trims the bank's description, falls back to Plaid's name for it, and says No description when there's neither" do
      adds tx("tx-1", description: "  LOBLAWS   #1234 \n", name: "Loblaws"), tx("tx-2", description: nil, name: " Loblaws "),
        tx("tx-3", description: " ", name: nil)

      sync

      expect(bank_transaction("tx-1").description).to eq("LOBLAWS   #1234")
      expect(bank_transaction("tx-2").description).to eq("Loblaws")
      expect(bank_transaction("tx-3").description).to eq("No description")
    end

    it "writes a content key and an occurrence, numbered on from what the Account has, as an Import's rows have (ADR 0010)" do
      adds tx("tx-1", amount: "4.00", description: "COFFEE"), tx("tx-2", amount: "4.00", description: "coffee ")
      sync
      adds tx("tx-3", amount: "4.00", description: "Coffee")

      sync

      key = Budget::BankTransaction.content_key(account_id: chequing.id, date: Date.new(2026, 10, 3), amount: BigDecimal("-4.00"), description: "Coffee")
      expect(bank_transactions.map { [ it.content_key, it.occurrence ] }).to eq([ [ key, 1 ], [ key, 2 ], [ key, 3 ] ])
    end

    it "brings in the same transaction once, however often it's read" do
      adds tx("tx-1")

      3.times do
        connection.forget_sync_cursor!
        sync
      end

      expect(bank_transactions.count).to eq(1)
    end

    it "leaves out a pending one, one in an account that isn't an Account of the connection, and one dated before its Account's date, without counting them" do
      adds tx("tx-1", pending: true), tx("tx-2", account: "left-out"), tx("tx-3", date: "2026-09-30"), tx("tx-4", account: "acc-2", date: "2026-09-01")

      result = sync

      expect(bank_transactions.map(&:external_id)).to eq([ "tx-4" ])
      expect(result).to have_attributes(created: 1, skipped: 0)
    end

    it "brings nothing new into an Account that's no longer shared, and leaves what it has as it is, uncounted" do
      adds tx("tx-1", account: "acc-2", amount: "10.00")
      sync
      visa.update!(unshared_at: Time.current)
      modifies tx("tx-1", account: "acc-2", amount: "99.00")
      removes "tx-1", account: "acc-2"
      adds tx("tx-2", account: "acc-2"), tx("tx-3")

      result = sync

      expect(bank_transaction("tx-1")).to have_attributes(amount: BigDecimal("-10.00"), removed_at: nil)
      expect(bank_transactions.map(&:external_id)).to eq([ "tx-1", "tx-3" ])
      expect(result).to have_attributes(created: 1, changed: 0, removed: 0, skipped: 0)
    end

    it "skips one in another currency and one of 0, and counts them" do
      adds tx("tx-1", currency: "USD"), tx("tx-2", currency: nil, unofficial_currency: "BTC"), tx("tx-3", amount: "0.00"), tx("tx-4", currency: nil)

      result = sync

      expect(bank_transactions).to be_empty
      expect(result).to have_attributes(created: 0, skipped: 4)
    end

    it "skips one it can't store as it is, and counts it" do
      adds tx("tx-1", amount: "1.005"), tx("tx-2", amount: nil), tx("tx-3", date: nil)

      result = sync

      expect(bank_transactions).to be_empty
      expect(result.skipped).to eq(3)
    end
  end

  describe "a modified transaction" do
    it "updates its bank transaction in place, and leaves its key, its occurrence and what it was filed as alone", :aggregate_failures do
      adds tx("tx-1", amount: "82.45", date: "2026-10-03", description: "LOBLAWS")
      sync
      row = bank_transaction("tx-1")
      spend = create(:budget_spend_link, bank_transaction: row).spend
      filed_as = spend.attributes
      key = row.content_key
      modifies tx("tx-1", amount: "80.00", date: "2026-10-04", authorized_date: "2026-10-02", description: "LOBLAWS #1234")

      result = sync

      expect(row.reload).to have_attributes(amount: BigDecimal("-80.00"), date: Date.new(2026, 10, 4), authorized_date: Date.new(2026, 10, 2),
        description: "LOBLAWS #1234", content_key: key, occurrence: 1)
      expect(spend.reload.attributes).to eq(filed_as)
      expect(row).to be_filed
      expect(result).to have_attributes(created: 0, changed: 1)
    end

    it "writes nothing when nothing about it changed" do
      adds tx("tx-1")
      sync
      updated_at = bank_transaction("tx-1").updated_at
      modifies tx("tx-1")

      result = travel(1.hour) { sync }

      expect(bank_transaction("tx-1").updated_at).to eq(updated_at)
      expect(result.changed).to eq(0)
    end

    it "brings one in as new when it was never stored, such as one dated before the Account's date until then" do
      adds tx("tx-1", date: "2026-09-20")
      sync
      modifies tx("tx-1", date: "2026-10-02")

      result = sync

      expect(bank_transaction("tx-1").date).to eq(Date.new(2026, 10, 2))
      expect(result.created).to eq(1)
    end

    it "restores one the bank had removed" do
      adds tx("tx-1")
      sync
      removes "tx-1"
      sync
      expect(bank_transaction("tx-1")).to be_removed

      modifies tx("tx-1", amount: "11.00")
      result = sync

      expect(bank_transaction("tx-1")).not_to be_removed
      expect(result.changed).to eq(1)
    end

    it "removes one that's now in another currency or of 0" do
      adds tx("tx-1"), tx("tx-2")
      sync
      modifies tx("tx-1", currency: "USD"), tx("tx-2", amount: "0.00")

      result = sync

      expect(bank_transactions).to all(be_removed)
      expect(result).to have_attributes(removed: 2, skipped: 0)
    end
  end

  describe "a removed transaction" do
    it "marks its bank transaction removed and keeps it, with what it last said and what it was filed as" do
      adds tx("tx-1", amount: "82.45")
      sync
      create(:budget_spend_link, bank_transaction: bank_transaction("tx-1"))
      removes "tx-1"

      result = sync

      expect(bank_transaction("tx-1")).to have_attributes(removed_at: be_present, amount: BigDecimal("-82.45"))
      expect(bank_transaction("tx-1")).to be_filed
      expect(result.removed).to eq(1)
    end

    it "does nothing for one it never stored, such as a pending one that posted" do
      adds tx("pending-1", pending: true), tx("posted-1")
      removes "pending-1"

      result = sync

      expect(bank_transactions.map(&:external_id)).to eq([ "posted-1" ])
      expect(result).to have_attributes(created: 1, removed: 0, skipped: 0)
    end

    it "keeps nothing of one that was added and removed between two syncs" do
      adds tx("tx-1")
      removes "tx-1"
      plaid.transactions_page_size = 1

      result = sync

      expect(bank_transactions).to be_empty
      expect(result).to have_attributes(created: 0, removed: 0)
    end

    it "says nothing new for one that's already removed" do
      adds tx("tx-1")
      sync
      removes "tx-1"
      sync
      removes "tx-1"

      expect(sync.removed).to eq(0)
    end
  end

  describe "Filing rules" do
    it "file what's new in an Account that has them on, and leave it to review, and leave an Account that has them off alone" do
      visa.update!(files_with_rules: false)
      rule = create(:budget_filing_rule, budget: budget, text: "loblaws")
      adds tx("tx-1", description: "LOBLAWS #1234"), tx("tx-2", account: "acc-2", description: "LOBLAWS #99")

      result = sync

      expect(bank_transaction("tx-1")).to have_attributes(filing_rule: rule)
      expect(bank_transaction("tx-1")).to be_filed.and be_to_review
      expect(bank_transaction("tx-2")).to be_unfiled
      expect(result).to have_attributes(created: 2, filed_by_rules: 1, ignored_by_rules: 0)
    end
  end

  describe "the cursor" do
    it "asks from none the first time, then from the cursor the last page gave, which is kept with when it finished" do
      adds tx("tx-1"), tx("tx-2"), tx("tx-3")
      plaid.transactions_page_size = 2

      travel_to(Time.utc(2026, 10, 8)) { sync }

      expect(plaid.transaction_requests).to eq([ [ "its-token", nil ], [ "its-token", "cursor-2" ] ])
      expect(connection.reload).to have_attributes(sync_cursor: "cursor-3", synced_at: Time.utc(2026, 10, 8))
      expect(bank_transactions.count).to eq(3)

      adds tx("tx-4")
      sync

      expect(plaid.transaction_requests.last).to eq([ "its-token", "cursor-3" ])
      expect(bank_transactions.count).to eq(4)
    end

    it "writes nothing until every page is read, so one that fails part way changes nothing" do
      adds tx("tx-1"), tx("tx-2"), tx("tx-3")
      plaid.transactions_page_size = 2
      allow(plaid).to receive(:transactions_sync).and_wrap_original do |original, *args, **options|
        raise PlaidApi::Error, "Plaid couldn't be reached." if options[:cursor] == "cursor-2"

        expect(Budget::BankTransaction.count).to eq(0)
        original.call(*args, **options)
      end

      result = sync

      expect(result.failure).to eq("Plaid couldn't be reached, so nothing was synced. Try again later.")
      expect(result.error).to be_a(PlaidApi::Error)
      expect(bank_transactions).to be_empty
      expect(connection.reload).to have_attributes(sync_cursor: nil, synced_at: nil)
    end

    it "starts the pages again from where the sync began when the bank's transactions change while they're read" do
      adds tx("tx-1"), tx("tx-2"), tx("tx-3")
      plaid.transactions_page_size = 2
      plaid.mutates_during_paging { adds tx("tx-4") }

      result = sync

      expect(plaid.transaction_requests.map(&:last)).to eq([ nil, "cursor-2", nil, "cursor-2" ])
      expect(bank_transactions.map(&:external_id)).to eq(%w[ tx-1 tx-2 tx-3 tx-4 ])
      expect(result.created).to eq(4)
      expect(connection.reload.sync_cursor).to eq("cursor-4")
    end

    it "gives up when they keep changing, changing nothing" do
      adds tx("tx-1"), tx("tx-2"), tx("tx-3")
      plaid.transactions_page_size = 2
      mutating = PlaidApi::Error.new(error_code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", status: 400)
      allow(plaid).to receive(:transactions_sync).and_wrap_original do |original, *args, **options|
        raise mutating if options[:cursor]

        original.call(*args, **options)
      end

      result = sync

      expect(plaid).to have_received(:transactions_sync).exactly((SyncPlaid::MAX_RESTARTS + 1) * 2).times
      expect(result).not_to be_success
      expect(result.error).to be_present
      expect(bank_transactions).to be_empty
    end

    it "keeps no cursor, and isn't synced yet, while Plaid hasn't gathered the bank's history" do
      plaid.not_ready("its-token")

      result = sync

      expect(result).to be_success
      expect(result.notice).to eq("TD Canada Trust hasn't sent its bank transactions yet. Try again in a few minutes.")
      expect(connection.reload).to have_attributes(sync_cursor: nil, synced_at: nil)
    end

    it "stops at more pages than it reads at once, changing nothing" do
      stub_const("SyncPlaid::MAX_PAGES", 2)
      adds tx("tx-1"), tx("tx-2"), tx("tx-3")
      plaid.transactions_page_size = 1

      result = sync

      expect(result.failure).to eq("TD Canada Trust sent more bank transactions than Budgie reads at once, so nothing was synced. Try again later.")
      expect(bank_transactions).to be_empty
    end

    it "is cleared by an Account's new date to read from, so the next sync reads every transaction again without bringing any in twice" do
      adds tx("tx-1", date: "2026-09-20"), tx("tx-2", date: "2026-10-02")
      sync
      expect(bank_transactions.map(&:external_id)).to eq([ "tx-2" ])

      chequing.change_read_from(Date.new(2026, 9, 1))
      result = sync

      expect(plaid.transaction_requests.last).to eq([ "its-token", nil ])
      expect(bank_transactions.map(&:external_id)).to contain_exactly("tx-1", "tx-2")
      expect(result).to have_attributes(created: 1, changed: 0)
    end
  end

  describe "what it says" do
    it "names the bank and only what isn't 0" do
      result = SyncPlaid::Result.new(bank: "TD Canada Trust", created: 9, changed: 2, removed: 1, skipped: 4, filed_by_rules: 2, ignored_by_rules: 0,
        not_ready: false, failure: nil, error: nil)

      expect(result.notice).to eq("Synced from TD Canada Trust: 9 new, 2 changed, 1 removed. 4 skipped. Filing rules filed 2 of them.")
      expect(result.with(created: 0, changed: 0, removed: 0, skipped: 0, filed_by_rules: 0).notice).to eq("Synced from TD Canada Trust: nothing new.")
    end
  end

  describe "when it fails" do
    %w[ ITEM_LOGIN_REQUIRED ACCESS_NOT_GRANTED NO_ACCOUNTS USER_SETUP_REQUIRED ].each do |code|
      it "marks the connection as needing reconnecting on #{code}, changing nothing and keeping the cursor" do
        adds tx("tx-1")
        sync
        adds tx("tx-2")
        plaid.fails_once(:transactions_sync, PlaidApi::Error.new(error_code: code, error_type: "ITEM_ERROR", status: 400))

        result = sync

        expect(result.failure).to eq("TD Canada Trust stopped accepting the connection, so nothing was synced.")
        expect(result.error).to be_nil
        expect(connection.reload).to be_needs_reconnect
        expect(connection.sync_cursor).to eq("cursor-1")
        expect(bank_transactions.map(&:external_id)).to eq([ "tx-1" ])
      end
    end

    it "asks to try later when Plaid is asked too often, without moving the cursor" do
      adds tx("tx-1")
      plaid.fails_once(:transactions_sync, PlaidApi::Error.new(error_code: "RATE_LIMIT_EXCEEDED", error_type: "RATE_LIMIT_EXCEEDED", status: 429))

      result = sync

      expect(result.failure).to eq("Plaid is limiting how often Budgie can ask, so nothing was synced. Try again later.")
      expect(result.error).to be_nil
      expect(connection.reload).to have_attributes(needs_reconnect: false, sync_cursor: nil, synced_at: nil)
      expect(bank_transactions).to be_empty
    end

    it "carries any other error of Plaid's, and changes nothing" do
      plaid.fails_once(:transactions_sync, PlaidApi::Error.new(error_code: "INTERNAL_SERVER_ERROR", error_type: "API_ERROR", status: 500))

      result = sync

      expect(result.failure).to eq("Plaid refused it (INTERNAL_SERVER_ERROR), so nothing was synced. Try again later.")
      expect(result.error).to be_a(PlaidApi::Error)
      expect(connection.reload).not_to be_needs_reconnect
      expect(connection).not_to be_disconnected
    end

    it "marks the connection disconnected when the Item is gone, such as removed at my.plaid.com, and says so, with nothing to raise" do
      adds tx("tx-1")
      plaid.fails_once(:transactions_sync, PlaidFake.item_not_found)

      result = sync

      expect(result.failure).to eq("TD Canada Trust was disconnected, since Plaid says it's no longer there, so nothing was synced.")
      expect(result.error).to be_nil
      expect(connection.reload).to be_disconnected
      expect(connection).not_to be_needs_reconnect
      expect(bank_transactions).to be_empty
      expect(chequing.reload).to be_synced
      expect(Budget::BankConnection.syncable).not_to include(connection)
    end

    it "lets an error that isn't Plaid's go, which rolls back, so the hourly job can log it with the connection" do
      adds tx("tx-1")
      allow(Budget::BankTransaction).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { sync }.to raise_error(ActiveRecord::StatementInvalid, "boom")

      expect(bank_transactions).to be_empty
      expect(connection.reload).to have_attributes(sync_cursor: nil, needs_reconnect: false)
    end

    it "marks the connection as needing reconnecting when the saved token can't be read, which is what a lost key leaves" do
      allow_any_instance_of(Budget::BankConnection).to receive(:access_token).and_raise(ActiveRecord::Encryption::Errors::Decryption)

      result = sync

      expect(result.failure).to eq("Budgie can't read the saved connection to TD Canada Trust, so nothing was synced.")
      expect(connection.reload).to be_needs_reconnect
    end

    it "does nothing for a connection that's disconnected, or that needs reconnecting, and doesn't ask Plaid" do
      connection.update_columns(needs_reconnect: true)
      expect(sync.failure).to eq("TD Canada Trust stopped accepting the connection, so it isn't syncing.")

      connection.disconnect!
      expect(sync.failure).to eq("This Account is disconnected from TD Canada Trust, so it isn't syncing.")

      expect(plaid.transaction_requests).to be_empty
    end

    it "never carries the token in what it says" do
      plaid.fails_once(:transactions_sync, PlaidApi::Error.new(error_code: "ITEM_LOGIN_REQUIRED", error_type: "ITEM_ERROR", status: 400))

      expect(sync.failure).not_to include("its-token")
    end
  end

  describe "holding the connection's lock" do
    it "locks the connection's row while it runs, so the hourly job and Sync now never both insert" do
      adds tx("tx-1")
      statements = []
      subscriber = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { sync }

      locking = statements.find { |sql| sql.include?('FROM "budget_bank_connections"') && sql.include?("FOR UPDATE") }
      expect(locking).to be_present
      expect(statements.index(locking)).to be < statements.index { |sql| sql.include?('"budget_bank_transactions"') }
    end
  end

  describe "the number of queries" do
    # A sync of `total` transactions in a budget of its own, over two Accounts: most of them already there and changed since (modified, or removed), and the rest new.
    def queries_for(total, rules: false)
      other_budget = create(:budget, currency: "CAD")
      token = "token-#{total}-#{rules}"
      other = create(:budget_bank_connection, :plaid, budget: other_budget, access_token: token)
      create(:budget_account, :plaid, budget: other_budget, bank_connection: other, external_account_id: "#{token}-a", files_with_rules: rules)
      create(:budget_account, :plaid, budget: other_budget, bank_connection: other, external_account_id: "#{token}-b", files_with_rules: rules)
      create(:budget_filing_rule, budget: other_budget, text: "merchant") if rules
      existing = total * 7 / 10
      made = ->(n, amount) { plaid.transaction("#{token}-#{n}", account: "#{token}-#{n.even? ? "a" : "b"}", amount: amount, date: "2026-10-#{format("%02d", (n % 28) + 1)}", description: "Merchant #{n}") }

      plaid.adds(token, *(1..existing).map { made.(it, "3.00") })
      described_class.call(other)
      (1..existing).each { |n| (n % 3).zero? ? plaid.removes(token, "#{token}-#{n}", account: "#{token}-a") : plaid.modifies(token, made.(n, "9.00")) }
      plaid.adds(token, *((existing + 1)..total).map { made.(it, "-4.00") })

      count_queries { described_class.call(other) }
    end

    it "is the same for 10 transactions as for 100, whatever they are: new, modified and removed" do
      expect(queries_for(100)).to eq(queries_for(10))
    end

    it "is the same with Filing rules on, however many bank transactions they file" do
      expect(queries_for(100, rules: true)).to eq(queries_for(10, rules: true))
    end
  end
end
