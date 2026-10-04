module ApplicationHelper
  # Formats an amount in the budget's currency unit, e.g. $1,234.50 or -$30.00.
  # The currency code is shown once in the page header rather than on every amount.
  def money(amount, budget:)
    number_to_currency(amount, unit: budget.currency_unit)
  end

  # What an envelope's Assigned in a month is called to someone who can't see where it sits on the page, such as
  # "Assigned to Groceries in September 2026". It names the Assigned cell's button and the input it opens.
  def assigned_to(envelope, month)
    "Assigned to #{envelope.name} in #{month.name}"
  end

  # The envelopes a picker offers, as [ name, id ] pairs, alphabetically: the budget's envelopes in use, and the ones
  # whose ids are in `keeping`, such as the envelope a record being edited is already in, which stays in its picker
  # even when it has been archived.
  def envelope_options(keeping: [])
    envelopes = Current.budget.envelopes
    envelopes.active.or(envelopes.where(id: keeping)).alphabetical.pluck(:name, :id)
  end

  # A link to one of the sections in the header. The one being looked at is marked as the current page.
  def section_link(name, path, current:)
    link_to name, path, class: [ "link link-hover py-1", ("font-semibold" if current) ], aria: { current: ("page" if current) }
  end

  # What's asked before an Import is undone, which lists what it deletes: the bank transactions it brought in, and the Deposits,
  # Spends and Refunds that they were filed as.
  def undo_confirmation(import, bank_transaction_count, filed: import.filed_record_counts)
    return "Undo the Import of #{import.file_name}? It added no bank transactions, so this only takes the Import away." if bank_transaction_count.zero?

    records = { deposits: "Deposit", spends: "Spend", refunds: "Refund" }.filter_map { |kind, noun| pluralize(filed[kind], noun) if filed[kind].positive? }
    "Undo the Import of #{import.file_name}? This deletes its #{pluralize(bank_transaction_count, "bank transaction")}" \
      "#{" and the #{records.to_sentence(last_word_connector: " and ")} filed from them" if records.any?}."
  end
end
