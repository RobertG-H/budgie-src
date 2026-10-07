require "rails_helper"

# A sync brings each Splitwise expense the person is part of into their Splitwise Account, as a bank transaction of their net share, and keeps it up to date
# as the expense is edited, deleted and restored (ADR 0016). It never changes a record that was filed from one. Specs never reach Splitwise: SplitwiseFake
# holds the expenses and answers a page at a time, as Splitwise does.
RSpec.describe SyncSplitwise do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:connection) { create(:budget_bank_connection, budget: budget, login_id: "4321", login_name: "Robert G.", access_token: "its-token", read_from: Date.new(2026, 10, 1)) }
  let!(:account) { create(:budget_account, :synced, budget: budget, name: "Splitwise", bank_connection: connection) }

  before { splitwise.signs_in("code", as: Splitwise::Person.new(id: "4321", name: "Robert G."), token: "its-token") }

  def sync
    described_class.call(connection)
  end

  def transactions
    account.bank_transactions.order(:id)
  end

  def transaction(external_id)
    account.bank_transactions.find_by!(external_id: external_id.to_s)
  end

  describe "bringing expenses in" do
    it "makes a bank transaction of the person's net share of each one, positive when friends owe them and negative when they owe", :aggregate_failures do
      splitwise.expense(1001, "Dinner at Nonna's", net_balance: "50.00", date: "2026-10-03")
      splitwise.expense(1002, "Groceries", net_balance: "-40.00", date: "2026-10-05")

      result = sync

      expect(result).to be_success
      expect(transactions.map { |t| [ t.external_id, t.description, t.amount, t.date ] }).to contain_exactly(
        [ "1001", "Dinner at Nonna's", 50, Date.new(2026, 10, 3) ], [ "1002", "Groceries", -40, Date.new(2026, 10, 5) ]
      )
      expect(transactions).to all(have_attributes(import: nil, ignored_at: nil, removed_at: nil, filing_rule_id: nil))
      expect(transactions).to all(be_unfiled)
      expect(result).to have_attributes(created: 2, changed: 0, deleted: 0, settle_ups: 0, skipped: 0)
    end

    it "keeps the description as Splitwise has it, trimmed, and says No description when it has none" do
      splitwise.expense(1, "  Brunch   at   the park \n", net_balance: "5.00")
      splitwise.expense(2, "   ", net_balance: "6.00")
      splitwise.expense(3, nil, net_balance: "7.00")

      sync

      expect(transaction(1).description).to eq("Brunch   at   the park")
      expect(transaction(2).description).to eq("No description")
      expect(transaction(3).description).to eq("No description")
    end

    it "makes each a bank transaction in the Splitwise Account, with a content key and an occurrence, as an Import's rows have (ADR 0010)" do
      splitwise.expense(1, "Coffee", net_balance: "-4.00", date: "2026-10-03")
      splitwise.expense(2, "coffee  ", net_balance: "-4.00", date: "2026-10-03")

      sync

      key = Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 10, 3), amount: BigDecimal("-4.00"), description: "Coffee")
      expect(transactions.map { |t| [ t.content_key, t.occurrence ] }).to contain_exactly([ key, 1 ], [ key, 2 ])
    end

    it "numbers an occurrence on from the ones the Account already has" do
      splitwise.expense(1, "Coffee", net_balance: "-4.00", date: "2026-10-03")
      sync
      splitwise.expense(2, "Coffee", net_balance: "-4.00", date: "2026-10-03")

      sync

      expect(transaction(1).occurrence).to eq(1)
      expect(transaction(2).occurrence).to eq(2)
    end

    it "brings in the same expense once, however often it's read" do
      splitwise.expense(1001, "Dinner", net_balance: "50.00")

      3.times { sync }

      expect(transactions.count).to eq(1)
    end

    it "says what it did, in words" do
      splitwise.expense(1, "Dinner", net_balance: "50.00")
      splitwise.expense(2, "Groceries", net_balance: "-40.00")

      expect(sync.notice).to eq("Synced from Splitwise: 2 new.")
    end

    it "says there's nothing new when nothing came in or changed" do
      expect(sync.notice).to eq("Synced from Splitwise: nothing new.")
    end

    it "is one bank transaction for each expense that can't be told apart from another by what it says, since the id is what it is" do
      splitwise.expense(1, "Coffee", net_balance: "-4.00", date: "2026-10-03")
      splitwise.expense(2, "Coffee", net_balance: "-4.00", date: "2026-10-03")

      sync

      expect(transactions.count).to eq(2)
    end

    it "reads page after page until one is short, so every expense is there however many there are" do
      (1..250).each { |n| splitwise.expense(n, "Expense #{n}", net_balance: "-1.00", date: "2026-10-#{format("%02d", (n % 28) + 1)}") }

      result = sync

      expect(transactions.count).to eq(250)
      expect(result.created).to eq(250)
      expect(splitwise.expense_requests.map { |request| request.values_at(:limit, :offset) }).to eq([ [ 100, 0 ], [ 100, 100 ], [ 100, 200 ] ])
    end

    it "asks for one more page after a full one, which is how it finds the last was full, and applies nothing from an empty one" do
      (1..100).each { |n| splitwise.expense(n, "Expense #{n}", net_balance: "-1.00") }

      sync

      expect(splitwise.expense_requests.map { |request| request[:offset] }).to eq([ 0, 100 ])
      expect(transactions.count).to eq(100)
    end

    it "asks Splitwise with the token the connection holds, for the connection's own Splitwise user" do
      sync

      expect(splitwise.expense_requests).to contain_exactly(include(token: "its-token", user_id: "4321"))
    end

    it "stops, and changes nothing, when the same expenses come round again, which is Splitwise ignoring the offset" do
      page = (1..100).map { |n| Splitwise::Expense.new(id: n.to_s, description: "E", date: Date.new(2026, 10, 3), currency_code: "CAD", payment: false, updated_at: Time.utc(2026, 10, 4), deleted_at: nil, net_balance: BigDecimal("-1")) }
      allow(splitwise).to receive(:expenses).and_return(page)

      result = sync

      expect(result).not_to be_success
      expect(result.failure).to eq("Splitwise sent the same expenses again, so nothing was synced. Try again later.")
      expect(transactions).to be_empty
    end
  end

  describe "where it reads from" do
    it "never reads an expense dated before the date to read from, and doesn't count it" do
      splitwise.expense(1, "Before", net_balance: "-5.00", date: "2026-09-30")
      splitwise.expense(2, "After", net_balance: "-6.00", date: "2026-10-02")

      result = sync

      expect(transactions.map(&:external_id)).to eq([ "2" ])
      expect(result).to have_attributes(created: 1, skipped: 0)
    end

    it "reads an expense dated on the very day, though Splitwise's own bound leaves it out" do
      splitwise.expense(1, "On the day", net_balance: "-5.00", date: "2026-10-01")

      sync

      expect(transactions.map(&:external_id)).to eq([ "1" ])
      # The day before, as a time: the bound isn't documented as including its own day, so the day itself is never at its edge.
      expect(splitwise.expense_requests.first[:dated_after]).to eq(Time.utc(2026, 9, 30))
    end

    it "asks with no `updated_after` the first time, and from a little before the marker after that" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00", updated_at: Time.utc(2026, 10, 5, 12, 0, 0))
      sync
      sync

      first, second = splitwise.expense_requests
      expect(first[:updated_after]).to be_nil
      expect(second[:updated_after]).to eq(Time.utc(2026, 10, 5, 11, 55, 0))
    end

    it "reads an expense again when it's within the overlap, which is harmless because it's matched by id" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00", updated_at: Time.utc(2026, 10, 5, 12, 0, 0))
      sync

      result = sync

      expect(splitwise.expense_requests.last[:updated_after]).to be < Time.utc(2026, 10, 5, 12, 0, 0)
      expect(result).to have_attributes(created: 0, changed: 0, deleted: 0)
      expect(transactions.count).to eq(1)
    end
  end

  describe "what's skipped, and counted" do
    it "is an expense the person isn't part of, or whose net share is 0, and nothing is stored for either" do
      splitwise.expense(1, "Between others", net_balance: nil)
      splitwise.expense(2, "Paid exactly my share", net_balance: "0.00")

      result = sync

      expect(transactions).to be_empty
      expect(result).to have_attributes(created: 0, skipped: 2)
    end

    it "is an expense in a currency other than the budget's" do
      splitwise.expense(1, "Trip in dollars", net_balance: "-30.00", currency_code: "USD")
      splitwise.expense(2, "Trip, with no currency", net_balance: "-30.00", currency_code: nil)

      result = sync

      expect(transactions).to be_empty
      expect(result.skipped).to eq(2)
    end

    it "reads the currency without regard to case" do
      splitwise.expense(1, "Dinner", net_balance: "-30.00", currency_code: "cad")

      expect(sync.created).to eq(1)
    end

    it "is an expense that's already deleted when it's first seen" do
      splitwise.expense(1, "Never mind", net_balance: "-30.00", deleted_at: Time.utc(2026, 10, 4))

      result = sync

      expect(transactions).to be_empty
      expect(result).to have_attributes(created: 0, deleted: 0, skipped: 1)
    end

    it "is one that can't be stored as it is: no id, no date, or a figure the amount column would round" do
      splitwise.expense(1, "No date", net_balance: "-5.00", date: nil)
      splitwise.expense(2, "Odd figure", net_balance: "-5.005")
      splitwise.expense(3, "Huge", net_balance: "10000000000000.00")
      allow(splitwise).to receive(:expenses).and_wrap_original do |original, *args, **options|
        original.call(*args, **options) + [ Splitwise::Expense.new(id: nil, description: "No id", date: Date.new(2026, 10, 3), currency_code: "CAD", payment: false, updated_at: nil, deleted_at: nil, net_balance: BigDecimal("-5")) ]
      end

      result = sync

      expect(transactions).to be_empty
      expect(result.skipped).to eq(4)
    end

    it "brings an expense in on the next sync once an edit gives the person a share, since nothing was stored to match it" do
      splitwise.expense(1, "Between others", net_balance: nil)
      sync
      splitwise.edit(1, net_balance: "25.00")

      result = sync

      expect(transaction(1).amount).to eq(25)
      expect(result).to have_attributes(created: 1, skipped: 0)
    end

    it "is in the notice, after the settle-ups" do
      splitwise.expense(1, "Between others", net_balance: nil)
      splitwise.expense(2, "Dinner", net_balance: "-30.00")
      splitwise.expense(3, "Jane paid me back", net_balance: "50.00", payment: true)

      expect(sync.notice).to eq("Synced from Splitwise: 1 new. 1 settle-up ignored, 1 skipped.")
    end
  end

  describe "settle-ups" do
    it "arrive ignored, with no Filing rule noted, since they move money between the person's own accounts" do
      splitwise.expense(7, "Jane paid me back", net_balance: "50.00", payment: true)
      splitwise.expense(8, "Dinner", net_balance: "-30.00")

      result = sync

      payment = transaction(7)
      expect(payment).to be_ignored
      expect(payment).to have_attributes(ignored_at: be_within(5.seconds).of(Time.current), filing_rule_id: nil, amount: 50)
      expect(transaction(8)).to be_unfiled
      expect(result).to have_attributes(created: 1, settle_ups: 1)
      expect(result.notice).to eq("Synced from Splitwise: 1 new. 1 settle-up ignored.")
    end

    it "can be un-ignored like any bank transaction, and a later sync doesn't ignore it again" do
      splitwise.expense(7, "Jane paid me back", net_balance: "50.00", payment: true)
      sync

      transaction(7).unignore
      sync

      expect(transaction(7)).to be_unfiled
    end

    it "stay ignored when they're edited, and are removed when they're deleted" do
      splitwise.expense(7, "Jane paid me back", net_balance: "50.00", payment: true)
      sync

      splitwise.edit(7, net_balance: "55.00")
      sync
      expect(transaction(7)).to have_attributes(amount: 55, ignored_at: be_present, removed_at: nil)

      splitwise.delete(7)
      sync
      expect(transaction(7)).to have_attributes(ignored_at: be_present, removed_at: be_present)
    end
  end

  describe "changes, which are matched by the id" do
    let!(:dinner) do
      splitwise.expense(1001, "Dinner", net_balance: "50.00", date: "2026-10-03")
      sync
      transaction(1001)
    end

    it "updates the date, amount and description in place, and never the content key or the occurrence", :aggregate_failures do
      splitwise.edit(1001, description: "Dinner at Nonna's", net_balance: "60.00", date: "2026-10-04")

      result = sync

      expect(transactions.count).to eq(1)
      expect(dinner.reload).to have_attributes(id: dinner.id, description: "Dinner at Nonna's", amount: 60, date: Date.new(2026, 10, 4), content_key: dinner.content_key, occurrence: 1)
      expect(dinner.content_key).to eq(Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 10, 3), amount: BigDecimal("50"), description: "Dinner"))
      expect(result).to have_attributes(created: 0, changed: 1, deleted: 0)
      expect(result.notice).to eq("Synced from Splitwise: 1 changed.")
    end

    it "changes the normalised description with the description, which the database keeps" do
      splitwise.edit(1001, description: "Brunch")

      sync

      expect(dinner.reload.normalized_description).to eq("brunch")
    end

    it "changes nothing about a row whose expense hasn't changed, not even when it was updated" do
      before = dinner.updated_at

      travel 1.hour do
        result = sync

        expect(result).to have_attributes(created: 0, changed: 0, deleted: 0, skipped: 0)
      end

      expect(dinner.reload.updated_at).to eq(before)
    end

    it "marks the bank transaction removed when the expense is deleted, and never deletes it" do
      splitwise.delete(1001)

      result = sync

      expect(transactions.count).to eq(1)
      expect(dinner.reload).to have_attributes(removed_at: be_within(5.seconds).of(Time.current), amount: 50, description: "Dinner", date: Date.new(2026, 10, 3))
      expect(result).to have_attributes(deleted: 1, changed: 0)
      expect(result.notice).to eq("Synced from Splitwise: 1 deleted.")
    end

    it "marks it removed when the person's share becomes 0, or they're no longer part of it" do
      splitwise.edit(1001, net_balance: "0.00")
      sync
      expect(dinner.reload).to be_removed

      splitwise.edit(1001, net_balance: "30.00")
      sync
      expect(dinner.reload).not_to be_removed
      expect(dinner.amount).to eq(30)

      splitwise.edit(1001, net_balance: nil)
      sync
      expect(dinner.reload).to be_removed
    end

    it "marks it removed when the expense is now in another currency" do
      splitwise.edit(1001, currency_code: "USD")

      sync

      expect(dinner.reload).to be_removed
    end

    it "clears removed when the expense is restored, and counts it as changed" do
      splitwise.delete(1001)
      sync
      splitwise.restore(1001)

      result = sync

      expect(dinner.reload.removed_at).to be_nil
      expect(result).to have_attributes(changed: 1, deleted: 0)
    end

    it "restores it with what Splitwise has now, when the expense was edited while it was deleted" do
      splitwise.delete(1001)
      sync
      splitwise.edit(1001, net_balance: "70.00", deleted_at: nil)

      sync

      expect(dinner.reload).to have_attributes(amount: 70, removed_at: nil)
    end

    it "keeps what it last saw of an expense that's deleted, and doesn't count a delete it already knew" do
      splitwise.delete(1001)
      sync
      removed_at = dinner.reload.removed_at

      travel 1.hour do
        result = sync

        expect(result).to have_attributes(deleted: 0, changed: 0)
      end

      expect(dinner.reload.removed_at).to eq(removed_at)
    end

    it "leaves one that's ignored ignored, and one that's filed filed, whatever changes", :aggregate_failures do
      groceries = create(:budget_envelope, budget: budget, name: "Groceries")
      splitwise.expense(2001, "Costco", net_balance: "-80.00", date: "2026-10-04")
      splitwise.expense(2002, "Ignored thing", net_balance: "-10.00", date: "2026-10-04")
      sync
      filed = transaction(2001)
      Budget::Filing.new(budget).file([ Budget::Filing::Entry.new(bank_transaction: filed, drafts: [ Budget::Filing::Draft.for(filed, kind: "spend", envelope_id: groceries.id) ]) ])
      transaction(2002).ignore

      splitwise.edit(2001, net_balance: "-90.00")
      splitwise.edit(2002, net_balance: "-12.00")
      sync

      expect(transaction(2001).reload).to be_filed
      expect(transaction(2002)).to be_ignored
    end

    it "never changes a record that was filed from it" do
      groceries = create(:budget_envelope, budget: budget, name: "Groceries")
      splitwise.expense(2001, "Costco", net_balance: "-80.00", date: "2026-10-04")
      sync
      filed = transaction(2001)
      Budget::Filing.new(budget).file([ Budget::Filing::Entry.new(bank_transaction: filed, drafts: [ Budget::Filing::Draft.for(filed, kind: "spend", envelope_id: groceries.id) ]) ])
      spend = groceries.spends.sole
      attributes = spend.attributes

      splitwise.edit(2001, net_balance: "-90.00", date: "2026-10-09", description: "Costco again")
      sync
      splitwise.delete(2001)
      sync

      expect(spend.reload.attributes).to eq(attributes)
      expect(filed.reload).to be_filed
      expect(filed).to have_attributes(amount: -90, removed_at: be_present)
      expect(filed).not_to be_adds_up
    end
  end

  describe "Filing rules" do
    let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
    let!(:rule) { create(:budget_filing_rule, budget: budget, text: "costco", envelope: groceries) }

    before do
      splitwise.expense(1, "Costco Wholesale", net_balance: "-80.00")
      splitwise.expense(2, "Jane paid me back for costco", net_balance: "-80.00", payment: true)
    end

    it "leave a synced Account's bank transactions alone while the Account has them off, as a new Account starts" do
      expect(account.files_with_rules).to be(false)

      result = sync

      expect(transaction(1)).to be_unfiled
      expect(result).to have_attributes(filed_by_rules: 0, ignored_by_rules: 0)
    end

    it "file the new ones when the Account has them on, through the filing operation, noting which rule did it" do
      account.update!(files_with_rules: true)

      result = sync

      filed = transaction(1)
      expect(filed).to be_filed
      expect(filed.filing_rule_id).to eq(rule.id)
      expect(groceries.spends.sole).to have_attributes(amount: 80, description: "Costco Wholesale", date: Date.new(2026, 10, 3))
      expect(result).to have_attributes(created: 1, filed_by_rules: 1, ignored_by_rules: 0)
      expect(result.notice).to eq("Synced from Splitwise: 1 new. 1 settle-up ignored. Filing rules filed 1 of them.")
    end

    it "leave what they file to review, and what they ignore, until a person has looked at it (ADR 0017)" do
      account.update!(files_with_rules: true)
      create(:budget_filing_rule, :ignore, budget: budget, text: "paid me back")
      splitwise.expense(3, "Jane paid me back again", net_balance: "-30.00")

      sync

      expect(Budget::BankTransaction.to_review.pluck(:external_id)).to contain_exactly("1", "3")
      expect(transaction(2)).not_to be_to_review
    end

    it "never act on a settle-up, which arrives ignored with no rule noted" do
      account.update!(files_with_rules: true)

      sync

      expect(transaction(2)).to be_ignored
      expect(transaction(2).filing_rule_id).to be_nil
      expect(transaction(2)).not_to be_filed
    end

    it "act only on a bank transaction that's new, and never on one that's changed" do
      sync
      account.update!(files_with_rules: true)
      splitwise.edit(1, description: "Costco Wholesale again")

      result = sync

      expect(transaction(1)).to be_unfiled
      expect(result.filed_by_rules).to eq(0)
    end

    it "is noted as ignored when the rule says to ignore" do
      rule.update!(outcome: "ignore", envelope: nil)
      account.update!(files_with_rules: true)

      result = sync

      expect(transaction(1)).to be_ignored
      expect(transaction(1).filing_rule_id).to eq(rule.id)
      expect(result.ignored_by_rules).to eq(1)
      expect(result.notice).to include("Filing rules ignored 1 of them.")
    end
  end

  describe "the sync marker" do
    it "moves to the latest `updated_at` it read when a sync finishes, and says when it ran", :aggregate_failures do
      splitwise.expense(1, "Dinner", net_balance: "-5.00", updated_at: Time.utc(2026, 10, 5, 9, 0, 0))
      splitwise.expense(2, "Groceries", net_balance: "-6.00", updated_at: Time.utc(2026, 10, 6, 15, 30, 45))

      travel_to Time.utc(2026, 10, 7, 12) do
        sync
      end

      expect(connection.reload.sync_cursor).to eq("2026-10-06T15:30:45Z")
      expect(connection.sync_marker).to eq(Time.utc(2026, 10, 6, 15, 30, 45))
      expect(connection.synced_at).to eq(Time.utc(2026, 10, 7, 12))
    end

    it "passes what it skipped, so a share of 0 isn't read again and again" do
      splitwise.expense(1, "Between others", net_balance: nil, updated_at: Time.utc(2026, 10, 6, 8, 0, 0))

      sync

      expect(connection.reload.sync_cursor).to eq("2026-10-06T08:00:00Z")
    end

    it "never moves back, even when what's read is older than it was, as the overlap makes it" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00", updated_at: Time.utc(2026, 10, 6, 8, 0, 0))
      sync
      connection.update_columns(sync_cursor: "2026-10-09T08:00:00Z")

      sync

      expect(connection.reload.sync_cursor).to eq("2026-10-09T08:00:00Z")
    end

    it "stays where it was when nothing is read, though a sync has finished" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00", updated_at: Time.utc(2026, 10, 6, 8, 0, 0))
      sync

      travel_to Time.utc(2026, 10, 8) do
        sync
      end

      expect(connection.reload.sync_cursor).to eq("2026-10-06T08:00:00Z")
      expect(connection.synced_at).to eq(Time.utc(2026, 10, 8))
    end

    it "is cleared by a new date to read from, so the next sync reads every expense dated from it again, without bringing in any twice" do
      splitwise.expense(1, "September", net_balance: "-5.00", date: "2026-09-10")
      splitwise.expense(2, "October", net_balance: "-6.00", date: "2026-10-10")
      sync
      expect(transactions.map(&:external_id)).to eq([ "2" ])

      connection.change_read_from(Date.new(2026, 9, 1))
      result = sync

      expect(splitwise.expense_requests.last[:updated_after]).to be_nil
      expect(transactions.map(&:external_id)).to contain_exactly("1", "2")
      expect(result).to have_attributes(created: 1, changed: 0)
    end

    it "leaves what's already in the Account as it is when the date to read from moves later" do
      splitwise.expense(1, "September", net_balance: "-5.00", date: "2026-10-02")
      sync

      travel_to Time.utc(2026, 10, 20, 15) do
        connection.change_read_from(Date.new(2026, 10, 15))
        sync
      end

      expect(transactions.map(&:external_id)).to eq([ "1" ])
      expect(transaction(1)).not_to be_removed
    end
  end

  describe "when it fails" do
    it "asks for a reconnect when Splitwise doesn't accept the token any more, changing nothing and keeping the marker" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00")
      sync
      connection.update_columns(sync_cursor: "2026-10-01T00:00:00Z")
      splitwise.expense(2, "Groceries", net_balance: "-6.00")
      splitwise.revoke("its-token")

      result = sync

      expect(result).not_to be_success
      expect(result.failure).to eq("Splitwise stopped accepting the sign-in as Robert G., so nothing was synced. Reconnect to start again.")
      expect(result.error).to be_nil
      expect(connection.reload).to be_needs_reconnect
      expect(connection.sync_cursor).to eq("2026-10-01T00:00:00Z")
      expect(transactions.map(&:external_id)).to eq([ "1" ])
    end

    it "asks to try later on a 429, changing nothing and not moving the marker, and the sign-in is still good" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00")
      splitwise.fails_at_offset(0, Splitwise::RateLimited.new("Splitwise is limiting how often Budgie can ask."))

      result = sync

      expect(result).not_to be_success
      expect(result.failure).to eq("Splitwise is limiting how often Budgie can ask, so nothing was synced. Try again later.")
      expect(result.error).to be_nil
      expect(connection.reload).not_to be_needs_reconnect
      expect(connection).to have_attributes(sync_cursor: nil, synced_at: nil)
      expect(transactions).to be_empty
    end

    it "rolls back the whole sync when it fails halfway, then reads everything the next time without duplicating any" do
      (1..150).each { |n| splitwise.expense(n, "Expense #{n}", net_balance: "-1.00", date: "2026-10-#{format("%02d", (n % 28) + 1)}") }
      splitwise.fails_at_offset(100, Splitwise::Error.new("Splitwise couldn't be reached."))

      failed = sync

      expect(failed).not_to be_success
      expect(failed.failure).to eq("Splitwise couldn't be reached, so nothing was synced. Try again later.")
      expect(failed.error).to be_a(Splitwise::Error)
      expect(transactions).to be_empty
      expect(connection.reload).to have_attributes(sync_cursor: nil, synced_at: nil, needs_reconnect: false)

      succeeded = sync

      expect(succeeded).to be_success
      expect(transactions.count).to eq(150)
      expect(transactions.pluck(:external_id).uniq.size).to eq(150)
      expect(succeeded.created).to eq(150)
    end

    it "lets an error that isn't Splitwise's go, which rolls back, so the hourly job can log it with the connection" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00")
      allow(Budget::BankTransaction).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { sync }.to raise_error(ActiveRecord::StatementInvalid, "boom")

      expect(transactions).to be_empty
      expect(connection.reload).to have_attributes(sync_cursor: nil, needs_reconnect: false)
    end

    it "asks for a reconnect when the saved token can't be read, which is what a lost key leaves" do
      allow_any_instance_of(Budget::BankConnection).to receive(:access_token).and_raise(ActiveRecord::Encryption::Errors::Decryption)

      result = sync

      expect(result).not_to be_success
      expect(result.failure).to eq("Budgie can't read the saved Splitwise sign-in, so nothing was synced. Reconnect to start again.")
      expect(connection.reload).to be_needs_reconnect
    end

    it "does nothing for a connection that's disconnected, or that needs reconnecting, and doesn't ask Splitwise" do
      connection.update_columns(needs_reconnect: true)
      expect(sync.failure).to eq("Splitwise stopped accepting the sign-in as Robert G., so it isn't syncing. Reconnect to start again.")

      connection.reconnect!(access_token: "its-token", login_name: "Robert G.")
      connection.disconnect!
      expect(sync.failure).to eq("This Account is disconnected from Splitwise, so it isn't syncing. Reconnect to start again.")

      expect(splitwise.expense_requests).to be_empty
    end

    it "never carries the token in what it says" do
      splitwise.revoke("its-token")

      expect(sync.failure).not_to include("its-token")
    end
  end

  describe "holding the connection's lock" do
    it "locks the connection's row while it runs, so the hourly job and Sync now never both insert" do
      splitwise.expense(1, "Dinner", net_balance: "-5.00")
      statements = []
      subscriber = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { sync }

      locking = statements.find { |sql| sql.include?('FROM "budget_bank_connections"') && sql.include?("FOR UPDATE") }
      expect(locking).to be_present
      expect(statements.index(locking)).to be < statements.index { |sql| sql.include?('"budget_bank_transactions"') }
    end
  end

  describe "the number of queries" do
    # A sync of `total` expenses on one page, in a budget of its own: most of them already in the Account and changed since (edited, or deleted), and the rest new. A page
    # that's full is followed by a request for an empty one, which applies nothing.
    def queries_for(total, rules: false)
      splitwise.forget_expenses
      other_budget = create(:budget, currency: "CAD")
      other_connection = create(:budget_bank_connection, budget: other_budget, login_id: "4321", access_token: "its-token", read_from: Date.new(2026, 10, 1))
      create(:budget_account, :synced, budget: other_budget, bank_connection: other_connection, files_with_rules: rules)
      create(:budget_filing_rule, budget: other_budget, text: "expense") if rules
      existing = total * 7 / 10

      (1..existing).each { |n| splitwise.expense(n, "Expense #{n}", net_balance: (n.even? ? "-3.00" : "4.00"), date: "2026-10-#{format("%02d", (n % 28) + 1)}") }
      described_class.call(other_connection)
      (1..existing).each { |n| (n % 3).zero? ? splitwise.delete(n) : splitwise.edit(n, net_balance: "9.00") }
      ((existing + 1)..total).each { |n| splitwise.expense(n, "Expense #{n}", net_balance: (n.even? ? "-3.00" : "4.00"), date: "2026-10-#{format("%02d", (n % 28) + 1)}") }

      count_queries { described_class.call(other_connection) }
    end

    it "is the same for a page of 10 expenses as for 100, whatever they are: new, edited and deleted" do
      expect(queries_for(100)).to eq(queries_for(10))
    end

    it "is the same with Filing rules on, however many bank transactions they file" do
      expect(queries_for(100, rules: true)).to eq(queries_for(10, rules: true))
    end
  end
end
