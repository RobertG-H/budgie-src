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
end
