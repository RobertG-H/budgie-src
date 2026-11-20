module AccountsHelper
  # The muted line under an Account's name in the list: where its bank transactions come from when it isn't a CSV file's, or that the bank stopped sharing its account,
  # and how many it has.
  def account_detail(account, transaction_count)
    count = transaction_count.zero? ? "No bank transactions yet." : pluralize(transaction_count, "bank transaction")
    if account.unshared?
      "No longer shared from #{account.synced_from}. #{count}"
    elsif account.synced?
      "Synced from #{account.synced_from}. #{count}"
    else
      count
    end
  end

  # What's asked before an Account is deleted, which says what goes with it: the Filing rules pinned to it, and the connection it's synced from when no other
  # Account is synced from it, which is always so for Splitwise. It only reaches an Account without bank transactions, which is the only one that can be deleted.
  # A bank's Account that isn't its connection's last leaves its bank account unmapped, which the sync skips and Choose accounts can bring back.
  def account_delete_question(account)
    "Delete the #{account.name_was} account?#{filing_rules_deleted_with(account)}#{connection_after_deleting(account)}"
  end

  # What deleting a synced Account does to its connection, or nothing for one that isn't synced or one of a disconnected bank's that isn't its last.
  def connection_after_deleting(account)
    return unless account.synced?
    return " Its connection to #{account.synced_from} is removed with it." if account.connection_siblings.none?

    connection = account.bank_connection
    " #{account.synced_from} will stop bringing in #{account.name_was}. Choose accounts can bring it back." if connection.plaid? && !connection.disconnected?
  end

  # When a synced Account last synced, in words: "Last synced 12 minutes ago.", or "Not synced yet." before one has finished.
  def last_synced_text(connection)
    connection.synced_at ? "Last synced #{time_ago_in_words(connection.synced_at)} ago." : "Not synced yet."
  end

  # What's asked before an Account's connection is disconnected: the token is forgotten, and everything that came through it stays.
  def disconnect_question(connection)
    "Disconnect #{connection.provider_name}? Budgie forgets its sign-in and stops syncing. The Account, its bank transactions and what they were filed as stay."
  end
end
