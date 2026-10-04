module ImportsHelper
  # What's asked before an Import is undone, which lists what it deletes: the bank transactions it brought in, and the Deposits,
  # Spends and Refunds that they were filed as.
  def undo_confirmation(import, bank_transaction_count)
    return "Undo the Import of #{import.file_name}? It added no bank transactions, so this only takes the Import away." if bank_transaction_count.zero?

    filed = import.filed_record_counts
    records = { deposits: "Deposit", spends: "Spend", refunds: "Refund" }.filter_map { |kind, noun| pluralize(filed[kind], noun) if filed[kind].positive? }
    "Undo the Import of #{import.file_name}? This deletes its #{pluralize(bank_transaction_count, "bank transaction")}" \
      "#{" and the #{records.to_sentence(last_word_connector: " and ")} filed from them" if records.any?}."
  end
end
