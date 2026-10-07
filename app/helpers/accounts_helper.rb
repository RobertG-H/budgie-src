module AccountsHelper
  # The muted line under an Account's name in the list: where its bank transactions come from when it isn't a CSV file's, and how many it has.
  def account_detail(account, transaction_count)
    count = transaction_count.zero? ? "No bank transactions yet." : pluralize(transaction_count, "bank transaction")
    account.synced? ? "Synced from #{account.synced_from}. #{count}" : count
  end

  # What's asked before an Account is deleted, which says what goes with it: the Filing rules pinned to it, and the connection it's synced from, since
  # Splitwise has no other Account to keep it for. It only reaches an Account without bank transactions, which is the only one that can be deleted.
  def account_delete_question(account)
    connection = " Its connection to #{account.synced_from} is removed with it." if account.synced?

    "Delete the #{account.name_was} account?#{filing_rules_deleted_with(account)}#{connection}"
  end

  # What's asked before an Account's connection is disconnected: the token is forgotten, and everything that came through it stays.
  def disconnect_question(connection)
    "Disconnect #{connection.provider_name}? Budgie forgets its sign-in and stops syncing. The Account, its bank transactions and what they were filed as stay."
  end
end
