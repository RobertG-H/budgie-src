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

  private
    # Deleted straight from the table in one statement, never through the has_many :through above, which would delete
    # the envelopes instead of the records.
    def delete_envelope_records
      Budget::Assignment.where(envelope: envelopes).delete_all
    end
end
