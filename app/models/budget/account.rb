# A real bank or card account that bank transactions come from. Budgie doesn't track what's in it (ADR 0001): it has no
# balance, no currency (it uses its budget's), no kind and no last four digits. It's only where an Import reads a file into,
# and where deduplication looks for a row that's already there (ADR 0010).
#
# It can remember which CSV format its bank's files use (`default_csv_format`), which an Import from the header uses to tell which Account
# a file is for, and which its own Import form starts on. It's optional, set by hand on the Account's form or by the first Import into it
# (Budget::Import#run), and an Import never changes one that's there.
#
# `files_with_rules` is on for every Account to start with, and means its bank transactions are filed or ignored by the Budget's Filing rules as they
# come in (ADR 0012). Turned off, no rule acts on them, so each waits unfiled for a person, while a Guess can still help. It's only ever read when a
# rule would act, which is when a bank transaction arrives and when a rule is saved: turning it on again files nothing that's already there, and turning it
# off leaves what rules already filed as it is.
#
# It's either imported into from CSV files or synced from a connection (`bank_connection`, with the provider's id for it in `external_account_id`), never both:
# a synced Account takes no Import (see Budget::Import), and a Splitwise connection has exactly one Account, which goes when the Account does (ADR 0016).
#
# A synced Account has the date it reads from (`read_from`): what the provider has dated before it is never read. It's the Account's and not the connection's,
# so that a connection with several Accounts can give each its own (ADR 0018), and an Account that isn't synced has none.
#
# A bank's account stops being shared when the person de-selects it in Choose accounts (`unshared_at`, ChoosePlaidAccounts): the Account keeps its bank transactions
# and stays synced, and a sync brings nothing new into it (SyncPlaid) until it's selected again.
class Budget::Account < ApplicationRecord
  belongs_to :budget
  belongs_to :default_csv_format, class_name: "Budget::CsvFormat", optional: true
  belongs_to :bank_connection, class_name: "Budget::BankConnection", optional: true
  # An Account with bank transactions can't be deleted: the model refuses with a reason, and the database's ON DELETE
  # RESTRICT is the backstop. Its Imports go with it, which only an Account without any of their bank transactions can
  # reach, so this stays after the check that refuses. Deleting the whole budget deletes them first (see Budget).
  has_many :bank_transactions, dependent: :restrict_with_error
  has_many :imports, dependent: :destroy
  # The Filing rules pinned to it, which fit nothing once it's gone. Only an Account without bank transactions can be deleted, so
  # none of them is named by a bank transaction that a rule filed there.
  has_many :filing_rules, dependent: :destroy

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false }
  validate :default_csv_format_is_in_this_budget
  validate :no_default_csv_format_when_synced
  validate :bank_connection_is_in_this_budget
  validate :external_account_id_is_the_login
  validates :external_account_id, presence: true, if: :bank_connection_id
  validates :external_account_id, absence: { message: "needs a connection" }, unless: :bank_connection_id
  validates :external_account_id, uniqueness: { scope: :bank_connection_id, message: "is already synced" }, if: :bank_connection_id
  # Asked of the connection itself and not its id, so the form that connects one can check the date against a connection that isn't made yet.
  validates :read_from, presence: true, if: :bank_connection
  validates :read_from, absence: { message: "needs a connection" }, unless: :bank_connection
  validate :read_from_is_a_date_that_could_be_real
  # A bank's name and mask for the account it's synced from, which say which real account it is (the ADR 0001 addendum). Only a synced Account has them.
  validates :external_name, :external_mask, :unshared_at, absence: { message: "needs a connection" }, unless: :bank_connection

  # Its connection goes with it when no other Account is synced from it, which is always so for Splitwise. After the Account's own row has gone,
  # since its foreign key is what keeps the connection from being deleted, and only reached when nothing refused the delete.
  after_destroy :delete_connection_nothing_uses

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }
  # Whether Filing rules act on their bank transactions (`files_with_rules`, see the top). One that's off has every bank transaction wait for a person.
  scope :with_filing_rules, -> { where(files_with_rules: true) }
  scope :without_filing_rules, -> { where(files_with_rules: false) }
  # The Accounts a CSV file can be imported into: the ones that aren't synced from a connection.
  scope :importable, -> { where(bank_connection_id: nil) }
  # The synced Accounts whose bank account is still shared: the ones a sync brings anything into.
  scope :shared, -> { where(unshared_at: nil) }

  # Where a new synced Account starts reading from: the date of the budget's earliest bank transaction, so that a shared expense the person paid for, whose
  # card charge is already there, gets its share back, or the 1st of this month when there are none.
  def self.default_read_from(budget)
    budget.bank_transactions.minimum(:date) || Budget.current_month
  end

  # Whether its bank transactions come from a connection, such as Splitwise, rather than from CSV files. It stays so when the connection is
  # disconnected, since what's there came from it and a CSV file read in would count some of it twice.
  def synced?
    bank_connection_id.present?
  end

  # Whether the bank stopped sharing its account, because the person de-selected it in Choose accounts.
  def unshared?
    unshared_at.present?
  end

  # What it's synced from, as the connection's name ("Splitwise", or a bank's, "TD Canada Trust"), or nothing for an Account known only from CSV files.
  def synced_from
    bank_connection&.name
  end

  # The other Accounts synced from the same connection, which what's done to the connection reaches too. None for one that isn't synced, or for Splitwise's.
  def connection_siblings
    return Budget::Account.none unless bank_connection

    bank_connection.accounts.where.not(id: id).alphabetical
  end

  # What money in starts as when one of its bank transactions is filed: a Deposit, as for a bank, except from Splitwise, where it's almost always friends paying
  # back a share, which is a Refund (ADR 0016). Only where the filing form starts: a Guess and a Filing rule say what they like.
  def money_in_kind
    bank_connection&.splitwise? ? "refund" : "deposit"
  end

  # Why it takes no Import, which is what a synced Account says when one is asked of it, or nothing for an Account that does.
  def import_refusal
    "is synced from #{synced_from}, so it takes no Import" if synced?
  end

  # The Import that ran last, which is the only one that can be undone, and the one whose CSV format the next Import
  # starts with. Imports made at the same moment go by the order they were made in.
  def latest_import
    imports.latest_first.first
  end

  # Changes the date to read from, which is true when it was changed or already was that, and false with the reasons on `errors` when it can't be. A new date means every
  # expense dated from it is to be read again, which a sync marker that's already past them would skip, so the connection's marker is forgotten with it. What's already in
  # the Account stays as it is, and what's read again is matched by id, so nothing is brought in twice. Nothing reads the connection's token, so it works for a connection
  # whose key has been lost too.
  def change_read_from(date)
    self.read_from = date
    return false unless valid?
    return true unless read_from_changed?

    transaction do
      update_columns(read_from: read_from, updated_at: Time.current)
      bank_connection.forget_sync_cursor!
    end
    true
  end

  private
    # The same limits as a CSV file's dates (Budget::CsvFormat::Reader): the day after today is allowed, since someone ahead of Eastern time may already be there.
    def read_from_is_a_date_that_could_be_real
      return if read_from.blank?

      if read_from > Date.current.tomorrow
        errors.add(:read_from, "can't be in the future")
      elsif read_from < Budget::CsvFormat::Reader::EARLIEST_DATE
        errors.add(:read_from, "can't be before #{Budget::CsvFormat::Reader::EARLIEST_DATE.year}")
      end
    end

    # A synced Account has no files, so no CSV format to read them with. Its form doesn't offer one, and this refuses it from any other way in.
    def no_default_csv_format_when_synced
      errors.add(:default_csv_format, "isn't used by an Account that's synced") if synced? && default_csv_format_id.present?
    end

    # Which budget a connection is in is up to the model too, and a connection that doesn't exist at all is refused the same way. Only the code that makes
    # a connection's Account sets it, and never a param.
    def bank_connection_is_in_this_budget
      return if bank_connection_id.blank?

      errors.add(:bank_connection, "isn't one of this budget's") unless bank_connection&.budget_id == budget_id
    end

    # For a Splitwise connection the external account is the Splitwise user themselves, so its id is the login's. That's what makes a Splitwise connection have
    # one Account: the unique index on the connection and the external id can't be satisfied twice.
    def external_account_id_is_the_login
      return unless bank_connection&.login_is_the_account? && external_account_id.present?

      errors.add(:external_account_id, "must be the #{bank_connection.provider_name} user's id") unless external_account_id == bank_connection.login_id
    end

    def delete_connection_nothing_uses
      bank_connection.destroy! if bank_connection && bank_connection.accounts.none?
    end

    # Which budget a CSV format is in is up to the model: no foreign key can say. A format that doesn't exist at all is refused the same way,
    # rather than left to the database's foreign key.
    def default_csv_format_is_in_this_budget
      return if default_csv_format_id.blank?

      errors.add(:default_csv_format, "isn't one of this budget's") unless default_csv_format&.budget_id == budget_id
    end
end
