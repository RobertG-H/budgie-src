require "rails_helper"

# Choose accounts on a bank that's already connected (ADR 0018): after Plaid Link's update mode with account selection, the selected accounts that aren't Accounts
# yet each become a new Account or are left out, an Account whose account isn't selected any more stops getting anything new, and one selected again starts again.
# Mapping anything resets the connection's cursor, so the next sync reads everything again, matched by id. PlaidFake stands in for Plaid.
RSpec.describe ChoosePlaidAccounts do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:connection) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust", access_token: "its-token", sync_cursor: "cursor-9") }
  let!(:chequing) do
    create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Chequing", external_account_id: "acc-1",
      external_name: "TD Every Day Chequing", external_mask: "4821")
  end
  let!(:savings) do
    create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Savings", external_account_id: "acc-2",
      external_name: "TD ePremium Savings", external_mask: "1100")
  end

  around { |example| travel_to(Time.zone.local(2026, 11, 19, 12)) { example.run } }
  before do
    plaid.item("its-token", accounts: [
      plaid.account("acc-1", "TD Every Day Chequing", mask: "4821"),
      plaid.account("acc-2", "TD ePremium Savings", mask: "1100", subtype: "savings"),
      plaid.account("acc-3", "Visa Infinite", mask: "7000", subtype: "credit card", type: "credit"),
      plaid.account("acc-4", "TD U.S. Dollar Account", mask: "2200", subtype: "savings", currency: "USD"),
      plaid.account("acc-5", "TD Line of Credit", mask: "3300", subtype: "line of credit", type: "credit")
    ])
  end

  # What Link's onSuccess sends: the whole selection, which here has de-selected TD ePremium Savings and selected two new ones.
  def selection(*ids)
    names = { "acc-1" => [ "TD Every Day Chequing", "4821" ], "acc-2" => [ "TD ePremium Savings", "1100" ], "acc-3" => [ "Visa Infinite", "7000" ],
              "acc-4" => [ "TD U.S. Dollar Account", "2200" ], "acc-5" => [ "TD Line of Credit", "3300" ], "acc-9" => [ "Crafted", "9999" ] }
    accounts = ids.each_with_index.to_h { |id, index| [ index.to_s, { id: id, name: names.fetch(id).first, mask: names.fetch(id).last } ] }
    PendingPlaidLink.for_selection(ActionController::Parameters.new(accounts: accounts).permit!, account: chequing)
  end

  def choose(link, params = nil)
    service = described_class.new(connection: connection, link: link)
    service.call(service.choices(params))
  end

  describe "#choices" do
    it "is only the selected accounts that aren't Accounts yet, named and dated as Connect's are, by their place in what Link sent" do
      choices = described_class.new(connection: connection, link: selection("acc-1", "acc-3", "acc-4")).choices

      expect(choices.map { it.shared_account.id }).to eq([ "acc-3", "acc-4" ])
      expect(choices.map(&:index)).to eq([ 1, 2 ])
      expect(choices.first).to have_attributes(becomes: "new", name: "TD Canada Trust Visa Infinite", read_from: Date.new(2026, 11, 1), left_out_reason: nil)
    end

    it "leaves out an account in another currency, whatever was sent for it, and says why, from what Plaid says of it" do
      choices = described_class.new(connection: connection, link: selection("acc-1", "acc-3", "acc-4")).choices({ "2" => { becomes: "new" } })

      expect(choices.last).to have_attributes(becomes: "leave", left_out_reason: "It's in USD and your budget is in CAD, so it can only be left out.")
      expect(plaid.account_requests).to eq([ "its-token" ])
    end

    it "is none when every selected account is already an Account, without asking Plaid" do
      service = described_class.new(connection: connection, link: selection("acc-2", "acc-1"))

      expect(service.new_accounts).to be_empty
      expect(plaid.account_requests).to be_empty
    end
  end

  describe "#call" do
    it "makes each new Account in the connection, from what Plaid says of it, and resets the cursor so the next sync reads everything again", :aggregate_failures do
      result = choose(selection("acc-1", "acc-2", "acc-3", "acc-4"), { "2" => { becomes: "new", name: "Visa", read_from: "2026-10-01" } })

      expect(result).to be_saved
      visa = budget.accounts.find_by!(name: "Visa")
      expect(visa).to have_attributes(bank_connection: connection, external_account_id: "acc-3", external_name: "Visa Infinite", external_mask: "7000",
        read_from: Date.new(2026, 10, 1), files_with_rules: true, unshared_at: nil)
      expect(budget.accounts.where(external_account_id: "acc-4")).to be_empty
      expect(connection.reload.sync_cursor).to be_nil
      expect(result.notice).to eq("Added Visa from TD Canada Trust. Its bank transactions arrive within the hour.")
    end

    it "leaves an Account whose account isn't selected any more with what it has, stops it getting anything new, and resets nothing for that alone" do
      result = choose(selection("acc-1", "acc-3"), { "1" => { becomes: "leave" } })

      expect(result).to be_saved
      expect(savings.reload).to be_unshared
      expect(savings.unshared_at).to eq(Time.current)
      expect(chequing.reload).not_to be_unshared
      expect(budget.accounts.count).to eq(2)
      expect(connection.reload.sync_cursor).to eq("cursor-9")
      expect(result.notice).to eq("TD Savings is no longer shared, so nothing new comes in.")
    end

    it "shares an Account again when it's selected again, which counts as mapping it and resets the cursor" do
      savings.update!(unshared_at: 1.day.ago)

      result = choose(selection("acc-1", "acc-2"))

      expect(savings.reload).not_to be_unshared
      expect(connection.reload.sync_cursor).to be_nil
      expect(result.notice).to eq("TD Savings is shared again.")
    end

    it "keeps an Account that's already no longer shared as it was" do
      savings.update!(unshared_at: 2.days.ago)

      result = choose(selection("acc-1"))

      expect(savings.reload.unshared_at).to eq(2.days.ago)
      expect(result.notice).to eq("Nothing changed on TD Canada Trust.")
    end

    it "says it all in one notice" do
      savings.update!(unshared_at: 1.day.ago)
      chequing_link = selection("acc-2", "acc-3")

      result = choose(chequing_link)

      expect(result.notice).to eq("Added TD Canada Trust Visa Infinite from TD Canada Trust. Its bank transactions arrive within the hour. " \
        "TD Savings is shared again. TD Chequing is no longer shared, so nothing new comes in.")
    end

    it "clears needs-reconnect, since update mode signed in to the bank again and Plaid answered" do
      connection.needs_reconnect!

      choose(selection("acc-1", "acc-2"))

      expect(connection.reload).to be_connected
    end

    it "says on the page what's wrong with a choice, and changes nothing" do
      result = choose(selection("acc-1", "acc-2", "acc-3"), { "2" => { becomes: "new", name: "TD Chequing" } })

      expect(result).to be_invalid
      expect(result.choices.last.errors[:name]).to eq([ "has already been taken" ])
      expect(budget.accounts.count).to eq(2)
      expect(connection.reload.sync_cursor).to eq("cursor-9")
    end

    it "refuses a selection with an account Plaid doesn't have, which was crafted, and changes nothing" do
      result = choose(selection("acc-1", "acc-9"))

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was changed, since the accounts chosen weren't the ones TD Canada Trust shares. Choose accounts again.")
      expect(savings.reload).not_to be_unshared
      expect(budget.accounts.count).to eq(2)
    end

    it "refuses once 30 minutes have passed since Link finished, without asking Plaid" do
      link = selection("acc-1", "acc-3")
      travel 31.minutes

      result = described_class.new(connection: connection, link: link).call([])

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was changed, since the accounts weren't chosen within 30 minutes. Choose accounts again.")
      expect(plaid.account_requests).to be_empty
    end

    it "says Plaid's refusal, and changes nothing" do
      service = described_class.new(connection: connection, link: selection("acc-1"))
      plaid.fails(:accounts, PlaidApi::Error.new(display_message: "The bank isn't answering."))

      result = service.call([])

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was changed. The bank isn't answering.")
      expect(savings.reload).not_to be_unshared
    end

    it "refuses a connection that was disconnected since" do
      link = selection("acc-1")
      connection.disconnect!

      result = described_class.new(connection: connection, link: link).call([])

      expect(result).to be_refused
      expect(result.alert).to eq("Nothing was changed, since TD Canada Trust isn't connected any more.")
    end

    it "holds the connection's lock, so it can't reset the cursor under a sync that's running" do
      service = described_class.new(connection: connection, link: selection("acc-1", "acc-2", "acc-3"))
      choices = service.choices
      expect(connection).to receive(:with_lock).and_call_original

      service.call(choices)
    end

    it "brings nothing in twice on the next sync, which reads everything again", :aggregate_failures do
      connection.update_columns(sync_cursor: nil)
      plaid.adds("its-token", plaid.transaction("tx-1", account: "acc-1", date: "2026-11-03"))
      SyncPlaid.call(connection)
      plaid.adds("its-token", plaid.transaction("tx-2", account: "acc-3", date: "2026-11-04"))

      choose(selection("acc-1", "acc-2", "acc-3"))
      result = SyncPlaid.call(connection.reload)

      expect(plaid.transaction_requests.last).to eq([ "its-token", nil ])
      expect(result).to have_attributes(created: 1, changed: 0)
      expect(Budget::BankTransaction.where(external_id: "tx-1").count).to eq(1)
      expect(Budget::BankTransaction.find_by!(external_id: "tx-2").account.external_account_id).to eq("acc-3")
    end
  end

  describe "linking onto an existing Account" do
    let!(:csv_visa) { create(:budget_account, budget: budget, name: "Visa", default_csv_format: create(:budget_csv_format, budget: budget)) }

    it "offers the Accounts it can link onto, and never one of this connection's" do
      choices = described_class.new(connection: connection, link: selection("acc-1", "acc-3")).choices

      expect(choices.sole.targets.map(&:name)).to eq([ "Visa" ])
    end

    it "moves the Account onto the connection, clears its Default CSV format, resets the cursor and says so", :aggregate_failures do
      create(:budget_bank_transaction, account: csv_visa, date: Date.new(2026, 11, 12))

      result = choose(selection("acc-1", "acc-2", "acc-3"), { "2" => { becomes: "link:#{csv_visa.id}", link_read_from: "2026-11-12" } })

      expect(result).to be_saved
      expect(csv_visa.reload).to have_attributes(name: "Visa", bank_connection: connection, external_account_id: "acc-3", external_name: "Visa Infinite",
        external_mask: "7000", read_from: Date.new(2026, 11, 12), default_csv_format: nil)
      expect(csv_visa.bank_transactions.count).to eq(1)
      expect(connection.reload.sync_cursor).to be_nil
      expect(result.notice).to eq("Visa keeps its bank transactions and is synced from TD Canada Trust now.")
    end

    it "moves a disconnected bank's Account here and deletes its old connection once it's empty" do
      old = create(:budget_bank_connection, :plaid, budget: budget)
      old_visa = create(:budget_account, :plaid, budget: budget, bank_connection: old, name: "Old Visa", unshared_at: 1.day.ago)
      old.disconnect!

      choose(selection("acc-1", "acc-2", "acc-3"), { "2" => { becomes: "link:#{old_visa.id}", link_read_from: "2026-11-01" } })

      expect(old_visa.reload).to have_attributes(bank_connection: connection, unshared_at: nil)
      expect(Budget::BankConnection.exists?(old.id)).to be(false)
    end

    it "refuses the same Account on two rows, and changes nothing" do
      result = choose(selection("acc-1", "acc-2", "acc-3", "acc-5"),
        { "2" => { becomes: "link:#{csv_visa.id}", link_read_from: "2026-11-01" }, "3" => { becomes: "link:#{csv_visa.id}", link_read_from: "2026-11-01" } })

      expect(result).to be_invalid
      expect(result.choices.last.errors[:becomes]).to eq([ "is already chosen for another account on this page" ])
      expect(csv_visa.reload).not_to be_synced
    end
  end
end
