# A user's budget. Everything in it is in one currency, chosen on the setup page.
class Budget < ApplicationRecord
  # The supported currencies, all with two decimal places. Add one here to offer it.
  # The unit is shown before amounts; the code is shown once in the page header.
  CURRENCIES = {
    "CAD" => { name: "Canadian dollar", unit: "$" },
    "USD" => { name: "US dollar", unit: "$" },
    "EUR" => { name: "Euro", unit: "€" },
    "GBP" => { name: "British pound", unit: "£" },
    "AUD" => { name: "Australian dollar", unit: "$" },
    "NZD" => { name: "New Zealand dollar", unit: "$" }
  }.freeze

  belongs_to :user
  has_many :envelopes, dependent: :destroy
  has_many :deposits, dependent: :destroy
  # How the budget's banks lay out their CSV downloads, the real accounts their bank transactions come from, and the files
  # read into them. An Import and a bank transaction belong to the budget through their Account, so these are only for reading.
  has_many :csv_formats, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :imports, through: :accounts
  has_many :bank_transactions, through: :accounts
  # Money assigned to the budget's envelopes, money spent from them, money that came back to them, money moved between
  # them and money moved out of them to Ready to Assign. They belong to the budget through their envelope (a Reallocation
  # between envelopes through its From envelope), so these are only for reading.
  has_many :assignments, through: :envelopes
  has_many :spends, through: :envelopes
  has_many :refunds, through: :envelopes
  has_many :envelope_reallocations, through: :envelopes, source: :outgoing_reallocations
  has_many :ready_to_assign_reallocations, through: :envelopes

  # An envelope with records can't be deleted, so the records of the budget's envelopes go before the envelopes do.
  # `prepend` runs this ahead of the callback that `has_many :envelopes` adds, wherever it's declared.
  before_destroy :delete_envelope_records, prepend: true
  # The importer's rows go before everything else, ahead of the envelopes' records and of the Deposits: a bank transaction
  # keeps its Account and Import from being deleted, an Import keeps its Account and CSV format, and a link keeps the record it
  # holds. Declared after the one above, so that it's the first to run.
  before_destroy :delete_importer_records, prepend: true

  # The latest month that has been started, which Assigned was copied into from the month before. A new budget's first
  # month gets no copy, so it starts as that month.
  attribute :assignments_copied_through, :date, default: -> { current_month }

  # Budgets whose current month hasn't been started yet.
  scope :with_months_to_start, -> { where(assignments_copied_through: ...current_month) }

  validates :currency, presence: true
  validates :currency, inclusion: { in: CURRENCIES.keys, message: "isn't supported" }, allow_blank: true

  # Budget::Envelope and later Budget:: models are named without the prefix in routes, params and
  # DOM ids (envelopes_path, params[:envelope]), while their tables keep it (budget_envelopes).
  def self.use_relative_model_naming?
    true
  end

  def self.currency_options
    CURRENCIES.map { |code, currency| [ "#{currency[:name]} (#{code})", code ] }
  end

  # The month that has begun, as the 1st: today's month by the app's time zone, which is Eastern Time, so a month begins
  # at midnight there.
  def self.current_month
    Date.current.beginning_of_month
  end

  def currency_unit
    CURRENCIES.fetch(currency)[:unit]
  end

  # Starts every month that has begun since the last one was started, up to and including the current month, in order, so
  # a month missed while nothing was running is started by the next run. Starting a month gives each envelope the Assigned
  # amount it had the month before, unless it already has one.
  #
  # It holds the budget's row lock, so two runs can't both start a month, and a month that has been started stays as the
  # user leaves it however often this runs.
  def start_new_months
    with_lock do
      start_month(assignments_copied_through.next_month) while assignments_copied_through < Budget.current_month
    end
  end

  private
    def start_month(month)
      copy_assignments(from: month.prev_month, to: month)
      update!(assignments_copied_through: month)
    end

    # In one query to read the month before and one to insert, however many envelopes there are. An envelope that already
    # has an amount for the month is skipped by the unique index, so what was entered ahead is kept. An archived envelope's
    # Assigned isn't copied, so it never gets an amount without the person putting it there.
    def copy_assignments(from:, to:)
      copies = assignments.merge(Budget::Envelope.active).where(month: from).pluck(:envelope_id, :amount).map do |envelope_id, amount|
        { envelope_id: envelope_id, month: to, amount: amount }
      end

      Budget::Assignment.insert_all(copies, unique_by: [ :envelope_id, :month ]) if copies.any?
    end

    # In the order that each one's foreign keys allow: the records that bank transactions were filed as, with their links, then
    # the bank transactions, then the Imports they came from, then the Accounts and CSV formats those were in. Deleted straight
    # from the tables in one statement each. The records go here, with their links, because a link keeps its record from being
    # deleted, which `delete_envelope_records` and the Deposits would run into.
    def delete_importer_records
      Budget::BankTransaction.delete_filed_records(Budget::BankTransaction.where(account: accounts))
      Budget::BankTransaction.where(account: accounts).delete_all
      Budget::Import.where(account: accounts).delete_all
      Budget::Account.where(budget: self).delete_all
      Budget::CsvFormat.where(budget: self).delete_all
    end

    # Deleted straight from the table in one statement, never through the has_many :through above, which would delete
    # the envelopes instead of the records.
    def delete_envelope_records
      Budget::Assignment.where(envelope: envelopes).delete_all
      Budget::Spend.where(envelope: envelopes).delete_all
      Budget::Refund.where(envelope: envelopes).delete_all
      Budget::EnvelopeReallocation.involving(envelopes).delete_all
      Budget::ReadyToAssignReallocation.where(envelope: envelopes).delete_all
    end
end
