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

  # What a guess that found a CSV format but wasn't certain says to check, in words, one note for each thing that isn't certain: the format when more
  # than one reads the file differently, and the Account when none, or more than one, has the format as its default. What's offered is already chosen
  # on the form that comes back, and nothing is imported until it's sent.
  def import_guess_notes(guess)
    notes = []
    notes << "More than one of your CSV formats reads this file. Check the CSV format." unless guess.format_certain?

    if guess.account.nil?
      notes << "None of your Accounts has the #{guess.csv_format.name} CSV format as its default, so choose the Account the file is for."
    elsif !guess.account_certain?
      notes << "More than one of your Accounts has the #{guess.csv_format.name} CSV format as its default, so check the Account the file is for."
    end

    notes
  end
end
