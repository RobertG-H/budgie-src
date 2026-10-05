module BankTransactionsHelper
  # What a record that a bank transaction was filed as is called to the person: "Spend from Groceries", "Refund to Groceries" or
  # "Deposit", which has no envelope.
  def filed_record_label(record)
    case record
    when Budget::Deposit then "Deposit"
    when Budget::Spend then "Spend from #{record.envelope.name}"
    when Budget::Refund then "Refund to #{record.envelope.name}"
    end
  end

  # Where the record is edited, which goes back to the month view of the month it's in, since that's where it's counted.
  def filed_record_path(record)
    month = record.is_a?(Budget::Deposit) ? record.month : record.date
    edit_polymorphic_path(record, month: month.strftime("%Y-%m"))
  end

  # The options of the State select on the Bank transactions page: every state, then each one.
  def bank_transaction_state_options
    [ [ "All", "all" ], [ "Unfiled", "unfiled" ], [ "Filed", "filed" ], [ "Ignored", "ignored" ] ]
  end

  # The options of its Account select: all of them, then each Account alphabetically.
  def bank_transaction_account_options(accounts)
    [ [ "All accounts", "" ] ] + accounts.map { |account| [ account.name, account.id ] }
  end

  # Which way money went, in words, since colour and a sign aren't the only way to say it: "Money out" for a negative amount, and
  # "Money in" for a positive one.
  def money_direction(amount)
    amount.negative? ? "Money out" : "Money in"
  end

  # What a filing form's records add up to, as they've been entered, against the bank transaction's amount: whether it's all of it,
  # some with the rest left, or too much, said in words. The filing-split Stimulus controller keeps it up to date as the records
  # change, in the same words, so what's here is what it starts as, and what a refused form comes back with.
  def filing_totals(entry, budget)
    amount = money(entry.bank_transaction.amount.abs, budget: budget)
    total = money(entry.total, budget: budget)
    remaining = entry.remaining

    if remaining.zero?
      "Adds up to #{total} of #{amount}."
    elsif remaining.positive?
      "Adds up to #{total} of #{amount}, with #{money(remaining, budget: budget)} left."
    else
      "Adds up to #{total} of #{amount}, which is #{money(remaining.abs, budget: budget)} over."
    end
  end

  # Whether a record still has an envelope to choose, which is where the filing form's focus starts: a Spend or a Refund with none. Otherwise it
  # starts on File, since a Deposit has no envelope and a Guess has chosen one. Never a field inside "Edit details".
  def filing_envelope_to_choose?(draft)
    draft.kind != "deposit" && draft.envelope_id.blank?
  end

  # The fields of a record the filing form keeps under "Edit details", which a record's error on any of opens it.
  FILING_DETAIL_FIELDS = %i[ description date amount month notes ].freeze

  # Whether a record's "Edit details" is open: nothing that needs a person's attention is ever left in a closed section. It is for a split,
  # which needs every record's amount; for a record with an error in it; and for one that comes back with something in it changed from the
  # bank's own. A Guess only changes the kind and the envelope, which aren't in it, so it never opens it.
  def filing_details_open?(entry, draft)
    entry.drafts.size > 1 || draft.errors.attribute_names.intersect?(FILING_DETAIL_FIELDS) || draft.edited_from?(entry.bank_transaction)
  end

  # What "Edit details" holds, in a line under its name so that closing it isn't a mystery: "LOBLAWS #1234 · Oct 3, 2026 · $82.45", with
  # ", counts toward November" for a Deposit that's saved for the month after its date. What isn't there yet, or isn't a figure, is left out.
  # The filing-details controller keeps it in step with the fields in the same words.
  def filing_details_summary(draft, budget)
    amount = BigDecimal(draft.amount.to_s, exception: false)
    parts = [ draft.description.to_s.squish.presence, (spelled_date(draft.date) if draft.date), (money(amount, budget: budget) if amount) ].compact.join(" · ")
    return parts unless draft.kind == "deposit" && draft.date && draft.month && draft.month != draft.date.beginning_of_month

    "#{parts}, counts toward #{draft.month.strftime(draft.month.year == draft.date.year ? "%B" : "%B %Y")}"
  end
end
