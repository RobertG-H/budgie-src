# One CSV file read into one Account, which brings in its bank transactions. The file isn't kept, only its name.
#
# It commits as soon as the file has been checked, with no preview: a file that can't be read creates nothing, and an
# Import that has run can be undone while it's the Account's latest (ADR 0011). One that adds no bank transactions, such as
# the same file imported twice, is still an Import: it's the Account's latest, so an earlier one can't be undone from under the
# rows it skipped.
class Budget::Import < ApplicationRecord
  # Raised when an Import can't be undone; the message says why, for the person who asked.
  class Refused < StandardError; end

  # How long after it ran an Import can be undone, so that one click can't wipe out weeks of filing.
  UNDO_WINDOW = 24.hours

  belongs_to :account
  belongs_to :csv_format
  has_many :bank_transactions, dependent: :restrict_with_error

  validates :file_name, presence: true
  validates :duplicates_skipped, :zero_rows_skipped, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :csv_format_is_in_the_accounts_budget

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }

  # What the Import brought in, which is all its summary shows: the dates, how many bank transactions were money in and how
  # many money out, and what they add up to, and the first row as it was read, so a wrong sign or a swapped day and month,
  # which both read without error, is seen straight away. A date range and a first row are none when it added nothing.
  Summary = Data.define(:count, :first_date, :last_date, :money_in_count, :money_in_total, :money_out_count, :money_out_total, :first_row)

  # In two queries, however many bank transactions there are.
  def summary
    @summary ||= begin
      count, first_date, last_date, money_in_count, money_in_total, money_out_count, money_out_total = bank_transactions.pick(
        Arel.sql("COUNT(*)"), Arel.sql("MIN(date)"), Arel.sql("MAX(date)"),
        Arel.sql("COUNT(*) FILTER (WHERE amount > 0)"), Arel.sql("COALESCE(SUM(amount) FILTER (WHERE amount > 0), 0)"),
        Arel.sql("COUNT(*) FILTER (WHERE amount < 0)"), Arel.sql("COALESCE(SUM(amount) FILTER (WHERE amount < 0), 0)")
      )

      Summary.new(count: count, first_date: first_date, last_date: last_date, money_in_count: money_in_count, money_in_total: money_in_total,
        money_out_count: money_out_count, money_out_total: money_out_total, first_row: (bank_transactions.order(:id).first if count.positive?))
    end
  end

  # Reads `file` with the CSV format and brings its rows into the Account, and is true when that worked. When the file can't be
  # read, or the Import is refused, nothing is created, it's false, and the reasons are on `errors`: for a file, the first row
  # that can't be read, by its line.
  #
  # The Account's rows are counted as the Account's lock is held, and the Account's other Imports take turns on it, so a double
  # submit imports once, and the second finds every row a duplicate. It's the same number of queries however many rows there
  # are: one to lock, one to find what's already there, one to make the Import and one to insert every bank transaction.
  def run(file)
    return refuse("Choose a file to import.") if file.nil?
    return false unless valid?

    reading = csv_format.read(file)
    return refuse(reading.refusal.message) if reading.refusal

    account.with_lock do
      rows = rows_to_insert(reading.rows)
      self.duplicates_skipped = reading.rows.size - rows.size
      self.zero_rows_skipped = reading.zero_rows
      save!
      Budget::BankTransaction.insert_all!(rows.map { |row| row.merge(import_id: id) }) if rows.any?
    end

    true
  end

  # Takes back the Import: deletes its bank transactions, then the Import, so the Account is as it was before it ran (ADR 0011).
  # It reaches only the Account's latest Import, and only within 24 hours of it running, and is refused with a message
  # otherwise. Once the latest is undone, the one before it is the latest, and can be undone in turn if it's still in time.
  #
  # It holds the Account's row lock, as running an Import does, so an Import can't land while it's undoing, and it's judged
  # once the lock is held, since another may have landed since the Import was looked at. It's all or nothing.
  def undo
    account.with_lock do
      reason = undo_refusal
      raise Refused, reason if reason

      # Straight from the table: `bank_transactions.delete_all` would only take them out of this Import, leaving them with none.
      Budget::BankTransaction.where(import: self).delete_all
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

    # Which budget an Account is in, and so which CSV formats it can be read with, is up to the model: no foreign key can say.
    def csv_format_is_in_the_accounts_budget
      return unless account && csv_format

      errors.add(:csv_format, "must be in the same budget as the account") if csv_format.budget_id != account.budget_id
    end
end
