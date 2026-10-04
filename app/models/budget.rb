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
  # Money assigned to the budget's envelopes. They belong to the budget through their envelope, so it's only for reading.
  has_many :assignments, through: :envelopes

  # An envelope with records can't be deleted, so the records of the budget's envelopes go before the envelopes do.
  # `prepend` runs this ahead of the callback that `has_many :envelopes` adds, wherever it's declared. Spends and
  # Refunds join Assignments in delete_envelope_records.
  before_destroy :delete_envelope_records, prepend: true

  # The latest month that has been started, which Assigned was copied into from the month before. A new budget's first
  # month gets no copy, so it starts as that month.
  attribute :assignments_copied_through, :date, default: -> { Date.current.beginning_of_month }

  # Budgets whose current month hasn't been started yet, which is the month of today's date in the app's time zone.
  scope :with_months_to_start, -> { where(assignments_copied_through: ...Date.current.beginning_of_month) }

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
      current_month = Date.current.beginning_of_month
      start_month(assignments_copied_through.next_month) while assignments_copied_through < current_month
    end
  end

  private
    def start_month(month)
      copy_assignments(from: month.prev_month, to: month)
      update!(assignments_copied_through: month)
    end

    # In one query to read the month before and one to insert, however many envelopes there are. An envelope that already
    # has an amount for the month is skipped by the unique index, so what was entered ahead is kept.
    def copy_assignments(from:, to:)
      copies = assignments.where(month: from).pluck(:envelope_id, :amount).map do |envelope_id, amount|
        { envelope_id: envelope_id, month: to, amount: amount }
      end

      Budget::Assignment.insert_all(copies, unique_by: [ :envelope_id, :month ]) if copies.any?
    end

    # Deleted straight from the table in one statement, never through the has_many :through above, which would delete
    # the envelopes instead of the records.
    def delete_envelope_records
      Budget::Assignment.where(envelope: envelopes).delete_all
    end
end
