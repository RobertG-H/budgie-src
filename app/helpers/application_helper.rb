module ApplicationHelper
  # Formats an amount in the budget's currency unit, e.g. $1,234.50 or -$30.00.
  # The currency code is shown once in the page header rather than on every amount.
  def money(amount, budget:)
    number_to_currency(amount, unit: budget.currency_unit)
  end
end
