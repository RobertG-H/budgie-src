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

  # A bank transaction's money in or money out, in words, since colour and a sign aren't the only way to say it.
  def money_direction(bank_transaction)
    bank_transaction.amount.negative? ? "Money out" : "Money in"
  end
end
