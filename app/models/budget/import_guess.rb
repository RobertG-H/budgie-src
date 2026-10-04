# What an Import from the header could work out about a file without being told: which of the budget's CSV formats reads it and which of its
# Accounts it's for, and how sure each is, or why nothing reads it. It's named so, and not "Guess", which is what's proposed for filing an unfiled
# bank transaction. See Budget::ImportGuesser, which makes it, and ADR 0014 for why an Import may run unconfirmed only when both are certain.
#
# - `csv_format` is the format that reads the file cleanly, or the best offer when more than one does and they read it differently, or none when
#   no format reads it. `format_certain?` is true when there's only one, or every one that does reads the same rows.
# - `account` is the Account that has that format as its default, or the best offer when several do, or none when none does. `account_certain?`
#   is true only when exactly one does.
# - `complete?` is when both are certain: the only guess that's imported without showing the form.
# - `refusals` is each format that didn't read the file and its first refusal, for explaining a file that nothing reads, and `file_refusal` is
#   what's wrong with the file itself when it's every format's, such as that it isn't UTF-8, in which case there's no list.
Budget::ImportGuess = Data.define(:csv_format, :account, :format_certain, :account_certain, :refusals, :file_refusal) do
  def self.nothing(refusals: [], file_refusal: nil)
    new(csv_format: nil, account: nil, format_certain: false, account_certain: false, refusals: refusals, file_refusal: file_refusal)
  end

  def format_certain?
    format_certain
  end

  def account_certain?
    account_certain
  end

  def complete?
    csv_format.present? && format_certain? && account.present? && account_certain?
  end
end

# A format that didn't read the file, and its first refusal.
Budget::ImportGuess::Rejection = Data.define(:csv_format, :refusal)
