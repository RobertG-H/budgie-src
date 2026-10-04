module RecordsHelper
  # The line under a record's description on the Records page, in words, so what kind of record it is and where it went is never
  # only a colour or a sign: "Spend from Groceries", "Refund to Groceries", "Deposit" (and which month it counts toward, when it's not
  # the month of its date), or "Reallocation from Dining out to Groceries" (or to Ready to Assign). An archived envelope's name has
  # its badge.
  def record_counterpart(record)
    case record
    when Budget::Spend then safe_join([ "Spend from ", record_envelope_name(record.envelope) ])
    when Budget::Refund then safe_join([ "Refund to ", record_envelope_name(record.envelope) ])
    when Budget::Deposit then deposit_counterpart(record)
    when Budget::EnvelopeReallocation
      safe_join([ "Reallocation from ", record_envelope_name(record.from_envelope), " to ", record_envelope_name(record.to_envelope) ])
    when Budget::ReadyToAssignReallocation
      safe_join([ "Reallocation from ", record_envelope_name(record.envelope), " to Ready to Assign" ])
    end
  end

  # What the amount of a record on the Records page is shown as: a Spend is negative, as every Spend is, a Reallocation is
  # positive and has no sign since it moves money that's already there, and a Deposit and a Refund are positive.
  def record_amount(record)
    record.is_a?(Budget::Spend) ? -record.amount : record.amount
  end

  # Where the record is edited, which comes back to the Records page as it was: the same filter and the same page of the list.
  # `edit_polymorphic_path` picks a Reallocation's table.
  def record_edit_path(record, list, page:)
    options = { from: "records", filter: list.to_params, page: (page unless page == 1) }.compact

    case record
    when Budget::Deposit then edit_deposit_path(record, **options)
    when Budget::Spend then edit_spend_path(record, **options)
    when Budget::Refund then edit_refund_path(record, **options)
    else edit_polymorphic_path(record, **options)
    end
  end

  # The options of the Kind select: every kind, then each one.
  def record_kind_options
    [ [ "All", "" ], [ "Deposit", "deposit" ], [ "Spend", "spend" ], [ "Refund", "refund" ], [ "Reallocation", "reallocation" ] ]
  end

  # The options of the Envelope select: all of them, then every envelope alphabetically, an archived one with "(archived)" after it.
  def record_envelope_options(envelopes)
    [ [ "All envelopes", "" ] ] + envelopes.map { |envelope| [ (envelope.archived? ? "#{envelope.name} (archived)" : envelope.name), envelope.id ] }
  end

  private
    # An envelope's name, with the Archived badge after it when it is.
    def record_envelope_name(envelope)
      envelope.archived? ? safe_join([ envelope.name, render("components/archived_badge") ], " ") : envelope.name
    end

    def deposit_counterpart(deposit)
      return "Deposit" if deposit.month == deposit.date.beginning_of_month

      safe_join([ "Deposit", tag.span("Counts toward #{deposit.month.to_fs(:month_and_year)}", class: "block") ], " ")
    end
end
