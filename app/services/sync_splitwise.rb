# Brings each Splitwise expense the person is part of into their Splitwise Account, as a bank transaction of their net share, and keeps it up to date as the
# expense is edited, deleted and restored (ADR 0016). Sync now and the hourly job (SyncBankConnectionsJob) both call it, once for a connection.
#
# It holds the connection's row lock for as long as it runs, as an Import holds its Account's, so the two can never both insert, and it's all one database
# transaction: a sync that fails, for any reason, changes nothing, and moves nothing, since the sync marker only moves forward when a sync finishes. The next
# one reads from a little before the marker, and reading an expense twice is harmless, because every expense is matched by its id.
#
# What it reads: `get_expenses`, a page at a time (`PAGE_SIZE`, with the limit and offset always set) until a short page, for what changed since the marker and is
# dated from the connection's read-from date. Each expense, by its id, is one of:
#
# - a new bank transaction, when the person has a share of it (net share other than 0, in the budget's currency, not deleted). Its amount is their net share,
#   signed, its date the day Splitwise shows (Splitwise::Expense), and its content key and occurrence are written once, as for an Import's rows. A settle-up (Splitwise's
#   `payment`) arrives ignored, with no Filing rule noted, and is counted apart from the rest.
# - skipped and counted, when it isn't one of those and isn't in the Account: nothing is stored, so an edit that later gives the person a share brings it in on
#   the next sync. Neither is one that can't be stored as it is: no id, no date, or an amount with more than 2 decimal places.
# - an update in place of the bank transaction it matches: its date, amount and description, never its content key, its occurrence or any record that was filed from it
#   (budget records are never changed automatically), and removed_at is cleared if it was set, which is a restore. Ignored stays ignored and filed stays filed.
# - removed, when the bank transaction it matches is for an expense that was deleted, or that now has no share or another currency: it gets `removed_at`, and is never deleted.
#
# Filing rules act on the new bank transactions as an Import's do, through the same applier, but only when the Account has them turned on, which a Splitwise Account
# doesn't to start with. It makes the same number of queries for each page of expenses however many are on it: the Account's rows for the page's ids, the occurrences of
# the new ones' keys, one insert and one update.
class SyncSplitwise
  # Splitwise's own default is 20, and a page is as long as it was asked for until the last, so this is how many to ask for and where to stop.
  PAGE_SIZE = 100
  # Far more than a person has, so that Splitwise ignoring the offset, or a listing that never ends, stops the sync instead of asking for ever.
  MAX_PAGES = 500
  # How far before the marker the next sync reads from, so an expense Splitwise stamped a moment before one that was read isn't missed.
  OVERLAP = 5.minutes

  # What a sync did, in the counts a person is told, or why it didn't. `created` doesn't include the settle-ups, which arrive ignored and are counted apart. A failure's
  # words are for a person and never carry the token or what Splitwise answered; `error` is the exception behind one the hourly job should raise (one that's
  # neither a rejected sign-in nor Splitwise asking to slow down, which are for the person to hear and nothing more).
  Result = Data.define(:created, :changed, :deleted, :settle_ups, :skipped, :filed_by_rules, :ignored_by_rules, :failure, :error) do
    def self.failed(failure, error: nil)
      new(created: 0, changed: 0, deleted: 0, settle_ups: 0, skipped: 0, filed_by_rules: 0, ignored_by_rules: 0, failure: failure, error: error)
    end

    def success?
      failure.nil?
    end

    # "Synced from Splitwise: 9 new, 2 changed, 1 deleted. 3 settle-ups ignored, 4 skipped." Only what isn't 0 is said.
    def notice
      changes = { created => "new", changed => "changed", deleted => "deleted" }.filter_map { |count, word| "#{count} #{word}" if count.positive? }
      others = [ ("#{settle_ups} #{"settle-up".pluralize(settle_ups)} ignored" if settle_ups.positive?), ("#{skipped} skipped" if skipped.positive?) ].compact

      [ "Synced from Splitwise: #{changes.join(", ").presence || "nothing new"}.", ("#{others.join(", ")}." if others.any?), rules_sentence ].compact.join(" ")
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
      result = refusal ? Result.failed(refusal) : sync
    end
    result
  rescue Splitwise::Rejected
    @connection.needs_reconnect!
    Result.failed("#{@connection.provider_name} stopped accepting the sign-in as #{@connection.login_name}, so nothing was synced. Reconnect to start again.")
  rescue Splitwise::Error => error
    Result.failed("#{error.message.delete_suffix(".")}, so nothing was synced. Try again later.", error: (error unless error.is_a?(Splitwise::RateLimited)))
  rescue ActiveRecord::Encryption::Errors::Decryption
    # The key the token was kept under has gone, so it can't be read: nothing but signing in again puts it right.
    @connection.needs_reconnect!
    Result.failed("Budgie can't read the saved #{@connection.provider_name} sign-in, so nothing was synced. Reconnect to start again.")
  end

  private
    # Why a connection isn't synced at all, judged when it's locked: it was disconnected, or the token was found not to work, since it was looked at.
    def refusal_for(connection)
      if connection.disconnected?
        "This Account is disconnected from #{connection.provider_name}, so it isn't syncing. Reconnect to start again."
      elsif connection.needs_reconnect?
        "#{connection.provider_name} stopped accepting the sign-in as #{connection.login_name}, so it isn't syncing. Reconnect to start again."
      end
    end

    def sync
      @account = @connection.accounts.first!
      @currency = @connection.budget.currency
      @read_from = @connection.read_from
      @now = Time.current
      @latest = @connection.sync_marker
      token = @connection.access_token
      updated_after = @latest && (@latest - OVERLAP)
      # The day before, as a time, since it isn't documented whether Splitwise's bound includes its own day. Whatever it leaves in that's before the read-from
      # date is dropped here, so the expenses on it are read and the ones before it never are.
      dated_after = @read_from.prev_day.in_time_zone("UTC")
      seen = Set.new
      offset = 0
      pages = 0

      loop do
        page = Splitwise.client.expenses(token, user_id: @connection.login_id, limit: PAGE_SIZE, offset: offset, updated_after: updated_after, dated_after: dated_after)
        ids = page.filter_map(&:id)
        raise Splitwise::Error, "Splitwise sent the same expenses again." if ids.any? && ids.all? { |id| seen.include?(id) }

        seen.merge(ids)
        apply(page)
        @latest = [ @latest, *page.filter_map(&:updated_at) ].compact.max
        break if page.size < PAGE_SIZE

        offset += PAGE_SIZE
        raise Splitwise::Error, "Splitwise sent more expenses than Budgie reads at once." if (pages += 1) >= MAX_PAGES
      end

      filed = apply_filing_rules
      @connection.update_columns(sync_cursor: @latest&.utc&.iso8601, synced_at: Time.current, updated_at: Time.current)

      Result.new(created: @counts[:created], changed: @counts[:changed], deleted: @counts[:deleted], settle_ups: @counts[:settle_ups], skipped: @counts[:skipped],
        filed_by_rules: filed.filed, ignored_by_rules: filed.ignored, failure: nil, error: nil)
    end

    # One page: the Account's rows for its ids in one query, what's new in one insert and what changed in one update, whatever's on it.
    def apply(page)
      # Dated before the date to read from, which is never read: it isn't skipped, since nothing about it was asked for.
      expenses = page.reject { |expense| expense.date && expense.date < @read_from }
      return if expenses.empty?

      existing = @account.bank_transactions.where(external_id: expenses.filter_map(&:id)).index_by(&:external_id)
      creates = []
      changes = {}
      expenses.each { |expense| read(expense, existing[expense.id], creates, changes) }

      insert(creates)
      Budget::BankTransaction.update_from_sync(changes)
    end

    # What one expense comes to, given the bank transaction it matches if it matches one.
    def read(expense, row, creates, changes)
      return skip if expense.id.nil?

      values = values_for(expense)

      if expense.deleted? || !share?(expense) || !in_budget_currency?(expense)
        row ? remove(row, changes) : skip
      elsif values.nil?
        skip unless row
      elsif row
        update(row, values, changes)
      else
        @counts[expense.payment ? :settle_ups : :created] += 1
        creates << values.merge(external_id: expense.id, settle_up: expense.payment)
      end
    end

    # The person has a share of it: they're part of it, and it isn't 0, which is what paying exactly one's own share, or an expense between others, comes to.
    def share?(expense)
      expense.net_balance.present? && !expense.net_balance.zero?
    end

    def in_budget_currency?(expense)
      expense.currency_code.to_s.casecmp?(@currency)
    end

    # What a bank transaction takes from the expense: the day, the description as Splitwise has it, and the person's net share. None for one that can't be stored as
    # it is: no date, or an amount the column would round or that's too large (Budget::BankTransaction validates it the same way).
    def values_for(expense)
      amount = expense.net_balance
      return if expense.date.nil? || amount.nil? || amount.round(2) != amount || amount.abs >= 10**13

      { date: expense.date, description: expense.description.to_s.strip.presence || Budget::CsvFormat::Reader::NO_DESCRIPTION, amount: amount }
    end

    # A bank transaction whose expense is gone, or has no share for the person, is removed, and kept: it keeps what it last said, and what was filed from it stays.
    # One that's already removed is nothing new.
    def remove(row, changes)
      return if row.removed?

      changes[row.id] = { date: row.date, description: row.description, amount: row.amount, removed_at: @now }
      @counts[:deleted] += 1
    end

    # In place, and only when something differs or it's a restore: reading an expense that hasn't changed writes nothing.
    def update(row, values, changes)
      return if values == { date: row.date, description: row.description, amount: row.amount } && !row.removed?

      changes[row.id] = values.merge(removed_at: nil)
      @counts[:changed] += 1
    end

    def skip
      @counts[:skipped] += 1
    end

    # The new ones, in one statement. Each is numbered from the last occurrence of its key that the Account already has, as an Import numbers its rows, and the
    # settle-ups are ignored as they arrive, with no Filing rule to say who did it.
    def insert(creates)
      return if creates.empty?

      keys = creates.map { |values| Budget::BankTransaction.content_key(account_id: @account.id, **values.slice(:date, :amount, :description)) }
      last = @account.bank_transactions.where(content_key: keys.uniq).group(:content_key).maximum(:occurrence)
      rows = creates.zip(keys).map do |values, key|
        last[key] = last.fetch(key, 0) + 1
        values.slice(:external_id, :date, :description, :amount).merge(account_id: @account.id, content_key: key, occurrence: last[key], ignored_at: (@now if values[:settle_up]))
      end

      ids = Budget::BankTransaction.insert_all!(rows, returning: %w[ id ]).rows.flatten
      @to_file.concat(creates.zip(ids).filter_map { |values, id| id unless values[:settle_up] })
    end

    # The Account's Filing rules act on what's new, if it has them on. A budget with no rules costs the one query that finds out.
    def apply_filing_rules
      none = Budget::FilingRule::Applier::Result.new(filed: 0, ignored: 0)
      return none unless @account.files_with_rules? && @to_file.any?

      applier = Budget::FilingRule::Applier.new(@connection.budget)
      return none if applier.rules.empty?

      applier.apply(@account.bank_transactions.where(id: @to_file).to_a)
    end
end
