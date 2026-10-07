# One CSV file read into one Account, which brings in its bank transactions. The file isn't kept, only its name.
#
# It commits as soon as the file has been checked, with no preview: a file that can't be read creates nothing, and an
# Import that has run can be undone while it's the Account's latest (ADR 0011). One that adds no bank transactions, such as
# the same file imported twice, is still an Import: it's the Account's latest, so an earlier one can't be undone from under the
# rows it skipped.
#
# The first Import into an Account that has no default CSV format makes the one it was read with the Account's (see Budget::Account).
#
# The budget's Filing rules act on the rows it creates, as they're created and in the same database transaction, so what a rule filed
# or ignored is undone with the Import like any other filed records (ADR 0012). It says how many in `filed_by_rules` and
# `ignored_by_rules`, which are what it did then: un-filing a row later doesn't change them.
class Budget::Import < ApplicationRecord
  # Raised when an Import can't be undone; the message says why, for the person who asked.
  class Refused < StandardError; end

  # How long after it ran an Import can be undone, so that one click can't wipe out weeks of filing.
  UNDO_WINDOW = 24.hours

  belongs_to :account
  belongs_to :csv_format
  has_many :bank_transactions, dependent: :restrict_with_error

  validates :file_name, presence: true
  validates :duplicates_skipped, :zero_rows_skipped, :money_in_count, :money_out_count, :filed_by_rules, :ignored_by_rules,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :csv_format_is_in_the_accounts_budget
  validate :account_takes_csv_imports

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }

  # The first row of the file as the CSV format read it, which the summary shows so that a wrong sign or a swapped day and month,
  # which both read without error, is seen straight away. None for a file with nothing in it but rows of 0.
  FirstRow = Data.define(:date, :description, :amount)

  def first_row
    FirstRow.new(date: first_row_date, description: first_row_description, amount: first_row_amount) if first_row_date
  end

  # How many bank transactions it brought in, which is what Undo would delete: the rows of the file less those already in the
  # Account (ADR 0010). It's counted, and not worked out from the file's figures, so what Undo says is what it does.
  def added_count
    @added_count ||= bank_transactions.count
  end

  # Reads `file` with the CSV format and brings its rows into the Account, and is true when that worked. When the file can't be
  # read, or the Import is refused, nothing is created, it's false, and the reasons are on `errors`: for a file, the first row
  # that can't be read, by its line.
  #
  # The Account's rows are counted as the Account's lock is held, and the Account's other Imports take turns on it, so a double
  # submit imports once, and the second finds every row a duplicate. It's the same number of queries however many rows there
  # are: one to lock, one to find what's already there, one to make the Import and one to insert every bank transaction. The Filing
  # rules add the same few again, however many rows and rules there are (see Budget::FilingRule::Applier).
  def run(file)
    return refuse("Choose a file to import.") if file.nil?
    return false unless valid?

    reading = csv_format.read(file)
    return refuse(reading.refusal.message) if reading.refusal

    account.with_lock do
      rows = rows_to_insert(reading.rows)
      self.duplicates_skipped = reading.rows.size - rows.size
      self.zero_rows_skipped = reading.zero_rows
      assign_attributes(file_figures(reading.rows))
      save!
      default_the_accounts_csv_format
      if rows.any?
        Budget::BankTransaction.insert_all!(rows.map { |row| row.merge(import_id: id) })
        apply_filing_rules
      end
    end

    true
  end

  # Takes back the Import: deletes the records its bank transactions were filed as, with their links, then the bank transactions,
  # then the Import, so the Account and the budget are as they were before it ran (ADR 0011).
  # It reaches only the Account's latest Import, and only within 24 hours of it running, and is refused with a message
  # otherwise. Once the latest is undone, the one before it is the latest, and can be undone in turn if it's still in time.
  #
  # It holds the Account's row lock, as running an Import does, so an Import can't land while it's undoing, and it's judged
  # once the lock is held, since another may have landed since the Import was looked at. It's all or nothing.
  def undo
    account.with_lock do
      reason = undo_refusal
      raise Refused, reason if reason

      # Straight from the tables: `bank_transactions.delete_all` would only take them out of this Import, leaving them with none.
      transactions = Budget::BankTransaction.where(import: self)
      Budget::BankTransaction.delete_filed_records(transactions)
      transactions.delete_all
      destroy!
    end

    self
  end

  # Why the Import can't be undone, or nothing when it can. Out of time is said first, since it's the one that won't change.
  def undo_refusal
    if !undo_window_open?
      "This Import ran more than 24 hours ago, so it can't be undone."
    elsif !latest?
      "This Import can't be undone while a newer Import is in this account. Undo that one first."
    end
  end

  # How many records of each kind its bank transactions were filed as, which Undo deletes too, so the confirmation can say so.
  def filed_record_counts
    Budget::BankTransaction.filed_record_counts(Budget::BankTransaction.where(import: self))
  end

  # Whether it's still within 24 hours of the Import running, which is all that undoing it is waiting on, once it's the latest.
  def undo_window_open?
    Time.current <= undo_window_ends_at
  end

  def undo_window_ends_at
    created_at + UNDO_WINDOW
  end

  # Whether it's the Account's most recent Import, which is the only one that can be undone.
  def latest?
    account.latest_import&.id == id
  end

  private
    # An Account without a default CSV format gets the one this Import was read with, since it worked, so the Account's next Import, and an
    # Import from the header, know which format its bank's files use. One that has a default is never changed by an Import. It's inside the
    # Account's row lock, which has just read its current value, and is one statement.
    def default_the_accounts_csv_format
      account.update_columns(default_csv_format_id: csv_format_id, updated_at: Time.current) if account.default_csv_format_id.nil?
    end

    # Files and ignores the rows it brought in that the budget's Filing rules fit, and notes how many. A budget with no rules costs the
    # one query that finds out.
    def apply_filing_rules
      applier = Budget::FilingRule::Applier.new(account.budget)
      return if applier.rules.empty?

      # Not through the association, which would keep them loaded, for Undo's restrict check to find after they're deleted.
      result = applier.apply(Budget::BankTransaction.where(import_id: id).to_a)
      update_columns(filed_by_rules: result.filed, ignored_by_rules: result.ignored)
    end

    # What the file held, which isn't kept, so it's worked out now for the summary to say later: of every row that isn't of 0,
    # whether it was already in the Account or not.
    def file_figures(rows)
      money_in, money_out = rows.partition { |row| row.amount.positive? }
      first = rows.first

      { earliest_date: rows.map(&:date).min, latest_date: rows.map(&:date).max,
        money_in_count: money_in.size, money_in_total: money_in.sum(&:amount), money_out_count: money_out.size, money_out_total: money_out.sum(&:amount),
        first_row_date: first&.date, first_row_description: first&.description, first_row_amount: first&.amount }
    end

    def refuse(reason)
      errors.clear
      errors.add(:base, reason)
      false
    end

    # What's new in the file (ADR 0010). For each content key, the file adds as many rows as it has beyond the ones the Account
    # already has, whatever has been done with them, and numbers them on from the last occurrence. The rest are duplicates,
    # which is the first ones in the file: an overlapping file starts with what's already there. The unique index on the
    # Account, key and occurrence is the backstop.
    def rows_to_insert(rows)
      keys = rows.map do |row|
        Budget::BankTransaction.content_key(account_id: account_id, date: row.date, amount: row.amount, description: row.description)
      end
      already_there = account.bank_transactions.where(content_key: keys.uniq).group(:content_key)
        .pluck(:content_key, Arel.sql("COUNT(*)"), Arel.sql("MAX(occurrence)")).to_h { |key, count, last| [ key, [ count, last ] ] }
      seen = Hash.new(0)

      rows.zip(keys).filter_map do |row, key|
        seen[key] += 1
        count, last = already_there.fetch(key, [ 0, 0 ])
        next if seen[key] <= count

        { account_id: account_id, date: row.date, description: row.description, amount: row.amount, content_key: key, occurrence: last + seen[key] - count }
      end
    end

    # An Account that's synced from a connection, such as Splitwise's, gets its bank transactions from there, and a CSV file read into it would count some of
    # them twice (ADR 0016). The UI doesn't offer one, and this refuses it from any other way in.
    def account_takes_csv_imports
      errors.add(:account, account.import_refusal) if account&.synced?
    end

    # Which budget an Account is in, and so which CSV formats it can be read with, is up to the model: no foreign key can say.
    def csv_format_is_in_the_accounts_budget
      return unless account && csv_format

      errors.add(:csv_format, "must be in the same budget as the account") if csv_format.budget_id != account.budget_id
    end
end
