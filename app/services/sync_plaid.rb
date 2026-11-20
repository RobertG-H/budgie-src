# Brings each posted transaction of a bank connected through Plaid into the Account it's for, as a bank transaction, and keeps it up to date as the bank changes
# or removes it (ADR 0018, docs/research/plaid-transactions-sync.md). Sync now and the hourly job (SyncBankConnectionsJob) both call it, once for a connection,
# which is one Plaid Item with one cursor for all its Accounts. It's shaped like SyncSplitwise:
#
# It holds the connection's row lock for as long as it runs, as an Import holds its Account's, so the two can never both insert, and it's all one database
# transaction: a sync that fails, for any reason, changes nothing, and moves nothing, since the cursor is kept only when a sync finishes.
#
# What it reads: `/transactions/sync` from the connection's cursor (none the first time, which is the whole history), a page at a time until Plaid says there's no
# more, and nothing is written until then, as Plaid asks. When the bank's transactions change while they're read, Plaid says so and every page is read again from
# where the sync began, a few times at most. While Plaid hasn't gathered the bank's history yet it answers an empty cursor, and nothing is kept, so the next sync
# asks from the start again.
#
# Each transaction is matched to an Account of the connection by Plaid's account id, and to a bank transaction by its id (`external_id`). One in an account that
# isn't an Account's (left out when connecting), a pending one (only posted ones are kept: a pending one that posts arrives again, as a new one) and one dated
# before its Account's date to read from are left out and not counted. Otherwise it's one of:
#
# - a new bank transaction: its amount is Plaid's negated, since Plaid's positive is money out, its date the date it posted on, which decides the month it's
#   filed in, its `authorized_date` kept for later, and its description the bank's own words (`original_description`), or else Plaid's name for it, never
#   Plaid's merchant. Its content key and occurrence are written once, as for an Import's rows (ADR 0010).
# - skipped and counted: in another currency, of 0, or that can't be stored as it is (no date, or an amount with more than 2 decimal places).
# - an update in place of the bank transaction it matches: its date, amount, description and authorised date, never its content key, its occurrence or any record
#   that was filed from it, and removed_at is cleared if it was set. Reading one that hasn't changed writes nothing.
# - removed, when the bank removed it, or it's now in another currency or of 0: it gets `removed_at`, and is never deleted. Removing one that was never stored, which
#   is what a pending one that posted is, does nothing.
#
# Filing rules act on the new bank transactions as an Import's do, through the same applier, in the Accounts that have them on, which a bank's do to start with. It
# makes the same number of queries for each page of transactions however many are on it.
class SyncPlaid
  # Far more pages of 500 than a bank has, so that a cursor that never ends stops the sync instead of asking for ever.
  MAX_PAGES = 200
  # How many times the pages are read again from the start when the bank's transactions keep changing while they're read.
  MAX_RESTARTS = 3
  # How many changes are written at once: each costs the same few queries however many are in it.
  BATCH_SIZE = PlaidApi::Client::TRANSACTIONS_PAGE_SIZE

  # What Plaid says when the bank's transactions changed while the pages were read: read them all again from where the sync began.
  MUTATION = "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION".freeze
  # What Plaid says when the bank stopped sharing with it, which only connecting again puts right (`needs_reconnect!`).
  NEEDS_RECONNECT = %w[ ITEM_LOGIN_REQUIRED ACCESS_NOT_GRANTED NO_ACCOUNTS USER_SETUP_REQUIRED ].freeze

  # What a sync did, in the counts a person is told, or why it didn't. `not_ready` is a sync that worked but found Plaid hasn't gathered the bank's transactions yet.
  # A failure's words are for a person and never carry the token or what Plaid answered; `error` is the exception behind one the hourly job should raise (one that's
  # neither the bank stopping sharing nor Plaid asking to slow down, which are for the person to hear and nothing more).
  Result = Data.define(:bank, :created, :changed, :removed, :skipped, :filed_by_rules, :ignored_by_rules, :not_ready, :failure, :error) do
    def self.failed(bank, failure, error: nil)
      new(bank: bank, created: 0, changed: 0, removed: 0, skipped: 0, filed_by_rules: 0, ignored_by_rules: 0, not_ready: false, failure: failure, error: error)
    end

    # A sync that worked, and found Plaid hasn't gathered the bank's transactions yet, so nothing was read or kept.
    def self.not_ready(bank)
      new(bank: bank, created: 0, changed: 0, removed: 0, skipped: 0, filed_by_rules: 0, ignored_by_rules: 0, not_ready: true, failure: nil, error: nil)
    end

    def success?
      failure.nil?
    end

    # "Synced from TD Canada Trust: 9 new, 2 changed, 1 removed. 4 skipped." Only what isn't 0 is said.
    def notice
      return "#{bank} hasn't sent its bank transactions yet. Try again in a few minutes." if not_ready

      changes = { created => "new", changed => "changed", removed => "removed" }.filter_map { |count, word| "#{count} #{word}" if count.positive? }
      [ "Synced from #{bank}: #{changes.join(", ").presence || "nothing new"}.", ("#{skipped} skipped." if skipped.positive?), rules_sentence ].compact.join(" ")
    end

    private
      def rules_sentence
        done = [ ("filed #{filed_by_rules}" if filed_by_rules.positive?), ("ignored #{ignored_by_rules}" if ignored_by_rules.positive?) ].compact
        "Filing rules #{done.join(" and ")} of them." if done.any?
      end
  end

  def self.call(connection)
    new(connection).call
  end

  def initialize(connection)
    @connection = connection
    @counts = Hash.new(0)
    @to_file = []
  end

  def call
    result = nil
    @connection.with_lock do
      refusal = refusal_for(@connection)
      result = refusal ? Result.failed(bank, refusal) : sync
    end
    result
  rescue PlaidApi::Error => error
    if NEEDS_RECONNECT.include?(error.error_code)
      @connection.needs_reconnect!
      Result.failed(bank, "#{bank} stopped accepting the connection, so nothing was synced.")
    elsif error.rate_limited?
      Result.failed(bank, "Plaid is limiting how often Budgie can ask, so nothing was synced. Try again later.")
    else
      Result.failed(bank, "#{error.message.delete_suffix(".")}, so nothing was synced. Try again later.", error: error)
    end
  rescue ActiveRecord::Encryption::Errors::Decryption
    # The key the token was kept under has gone, so it can't be read: nothing but connecting again puts it right.
    @connection.needs_reconnect!
    Result.failed(bank, "Budgie can't read the saved connection to #{bank}, so nothing was synced.")
  end

  private
    # The bank's name, which is what a person knows the connection by.
    def bank
      @connection.name
    end

    # Why a connection isn't synced at all, judged when it's locked: it was disconnected, or found to need reconnecting, since it was looked at.
    def refusal_for(connection)
      if connection.disconnected?
        "This Account is disconnected from #{bank}, so it isn't syncing."
      elsif connection.needs_reconnect?
        "#{bank} stopped accepting the connection, so it isn't syncing."
      end
    end

    def sync
      @accounts = @connection.accounts.to_a.index_by(&:external_account_id)
      @currency = @connection.budget.currency
      @now = Time.current
      changes, cursor = read_everything(@connection.access_token)
      return Result.not_ready(bank) if cursor.empty?

      changes.each_slice(BATCH_SIZE) { apply(it) }
      filed = apply_filing_rules
      @connection.update_columns(sync_cursor: cursor, synced_at: Time.current, updated_at: Time.current)

      Result.new(bank: bank, created: @counts[:created], changed: @counts[:changed], removed: @counts[:removed], skipped: @counts[:skipped],
        filed_by_rules: filed.filed, ignored_by_rules: filed.ignored, not_ready: false, failure: nil, error: nil)
    end

    # Every page from the cursor the sync began with, until Plaid says there's no more, as the latest change to each transaction and the cursor to keep. When the
    # bank's transactions change while they're read, it starts again from that same cursor, as Plaid says to.
    def read_everything(token)
      restarts = 0
      begin
        read_pages(token, @connection.sync_cursor.presence)
      rescue PlaidApi::Error => error
        raise unless error.error_code == MUTATION && (restarts += 1) <= MAX_RESTARTS

        retry
      end
    end

    # Within a page, what was removed comes after what was added and modified, and a later page's change to a transaction after an earlier one's, so the last
    # change to each is what's kept.
    def read_pages(token, cursor)
      latest = {}

      MAX_PAGES.times do
        page = PlaidApi.client.transactions_sync(token, cursor: cursor)
        (page.added + page.modified + page.removed).each { latest[it.id] = it }
        cursor = page.next_cursor
        return [ latest.values, cursor ] unless page.has_more
      end

      raise PlaidApi::Error, "#{bank} sent more bank transactions than Budgie reads at once."
    end

    # A batch of changes: the rows they match in one query, what's new in one insert and what changed in one update, whatever's in it.
    def apply(changes)
      existing = Budget::BankTransaction.where(account_id: @accounts.values.map(&:id), external_id: changes.map(&:id)).index_by(&:external_id)
      creates = []
      updates = {}
      changes.each { read(it, existing[it.id], creates, updates) }

      insert(creates)
      Budget::BankTransaction.update_from_sync(updates)
    end

    # What one change comes to, given the bank transaction it matches if it matches one.
    def read(change, row, creates, updates)
      return (remove(row, updates) if row) if change.is_a?(PlaidApi::RemovedTransaction)

      account = @accounts[change.account_id]
      return if account.nil? || change.pending || (change.date && change.date < account.read_from)

      values = values_for(change)

      if !change.in_currency?(@currency) || change.amount&.zero?
        row ? remove(row, updates) : skip
      elsif values.nil?
        skip unless row
      elsif row
        update(row, values, updates)
      else
        @counts[:created] += 1
        creates << values.merge(external_id: change.id, account: account)
      end
    end

    # What a bank transaction takes from the transaction: the day it posted, the bank's description, the amount as Budgie signs it and when it was authorised. None
    # for one that can't be stored as it is: no date, or an amount the column would round or that's too large (Budget::BankTransaction validates it the same way).
    def values_for(change)
      amount = change.amount && -change.amount
      return if change.date.nil? || amount.nil? || amount.round(2) != amount || amount.abs >= 10**13

      description = change.original_description.to_s.strip.presence || change.name.to_s.strip.presence || Budget::CsvFormat::Reader::NO_DESCRIPTION
      { date: change.date, description: description, amount: amount, authorized_date: change.authorized_date }
    end

    def stored_values(row)
      { date: row.date, description: row.description, amount: row.amount, authorized_date: row.authorized_date }
    end

    # Removed, and kept: it keeps what it last said, and what was filed from it stays. One that's already removed is nothing new.
    def remove(row, updates)
      return if row.removed?

      updates[row.id] = stored_values(row).merge(removed_at: @now)
      @counts[:removed] += 1
    end

    # In place, and only when something differs or it's a restore.
    def update(row, values, updates)
      return if values == stored_values(row) && !row.removed?

      updates[row.id] = values.merge(removed_at: nil)
      @counts[:changed] += 1
    end

    def skip
      @counts[:skipped] += 1
    end

    # The new ones, in one statement. Each is numbered from the last occurrence of its key that its Account already has, as an Import numbers its rows; the key
    # is a digest that includes the Account, so the keys of every Account can be looked up at once.
    def insert(creates)
      return if creates.empty?

      keys = creates.map { |values| Budget::BankTransaction.content_key(account_id: values[:account].id, **values.slice(:date, :amount, :description)) }
      last = Budget::BankTransaction.where(account_id: @accounts.values.map(&:id), content_key: keys.uniq).group(:content_key).maximum(:occurrence)
      rows = creates.zip(keys).map do |values, key|
        last[key] = last.fetch(key, 0) + 1
        values.slice(:external_id, :date, :description, :amount, :authorized_date).merge(account_id: values[:account].id, content_key: key, occurrence: last[key])
      end

      ids = Budget::BankTransaction.insert_all!(rows, returning: %w[ id ]).rows.flatten
      @to_file.concat(creates.zip(ids).filter_map { |values, id| id if values[:account].files_with_rules? })
    end

    # The Filing rules act on what's new in the Accounts that have them on. A budget with no rules costs the one query that finds out.
    def apply_filing_rules
      none = Budget::FilingRule::Applier::Result.new(filed: 0, ignored: 0)
      return none if @to_file.empty?

      applier = Budget::FilingRule::Applier.new(@connection.budget)
      return none if applier.rules.empty?

      applier.apply(Budget::BankTransaction.where(id: @to_file).to_a)
    end
end
