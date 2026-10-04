module ApplicationHelper
  # Formats an amount in the budget's currency unit, e.g. $1,234.50 or -$30.00.
  # The currency code is shown once in the page header rather than on every amount.
  def money(amount, budget:)
    number_to_currency(amount, unit: budget.currency_unit)
  end

  # Where a Reallocation is edited, whichever table it's in: a Reallocation to an envelope and one to Ready to Assign have
  # an edit page each, since their ids repeat.
  def edit_reallocation_path(reallocation, **options)
    if reallocation.is_a?(Budget::ReadyToAssignReallocation)
      edit_ready_to_assign_reallocation_path(reallocation, **options)
    else
      edit_envelope_reallocation_path(reallocation, **options)
    end
  end

  # What an envelope's Assigned in a month is called to someone who can't see where it sits on the page, such as
  # "Assigned to Groceries in September 2026". It names the Assigned cell's button and the input it opens.
  def assigned_to(envelope, month)
    "Assigned to #{envelope.name} in #{month.name}"
  end
end
