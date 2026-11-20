module AccountsHelper
  # The muted line under an Account's name in the list: where its bank transactions come from when it isn't a CSV file's, or that the bank stopped sharing its account,
  # and how many it has.
  def account_detail(account, transaction_count)
    count = transaction_count.zero? ? "No bank transactions yet." : pluralize(transaction_count, "bank transaction")
    if account.bank_connection&.plaid? && account.bank_connection.disconnected?
      "Was synced from #{account.synced_from}, which was disconnected. #{count}"
    elsif account.unshared?
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

  # What deleting a synced Account does to its connection, or nothing for one that isn't synced or one of a disconnected bank's that isn't its last. A live bank's last
  # Account takes its Item at Plaid with it, which ends Budgie's access to the bank.
  def connection_after_deleting(account)
    return unless account.synced?

    bank = account.synced_from
    if account.connection_siblings.none?
      " Its connection to #{bank} is removed with it#{", and Budgie stops having access to #{bank}" if account.removes_item_with_it?}."
    elsif account.bank_connection.plaid? && !account.bank_connection.disconnected?
      " #{bank} will stop bringing in #{account.name_was}. Choose accounts can bring it back."
    end
  end

  # When a synced Account last synced, in words: "Last synced 12 minutes ago.", or "Not synced yet." before one has finished.
  def last_synced_text(connection)
    connection.synced_at ? "Last synced #{time_ago_in_words(connection.synced_at)} ago." : "Not synced yet."
  end

  # What's asked before a bank is disconnected (Plaid's Item removed, for good): which Accounts stop syncing, that they keep their bank transactions, and that coming back is
  # a new connection, which counts against Plaid's Trial: the one place the app says so. Those that stop syncing are the ones the bank still shares.
  def disconnect_bank_question(connection)
    accounts = connection.accounts.shared.alphabetical.to_a.presence || connection.accounts.alphabetical.to_a
    names = accounts.map(&:name).to_sentence
    one = accounts.one?
    "Disconnect #{connection.name}? #{names} #{one ? "stops" : "stop"} syncing and #{one ? "keeps its" : "keep their"} bank transactions. " \
      "Connecting #{connection.name} again later counts as a new connection on Plaid's Trial."
  end

  # What's asked before an Account's connection is disconnected: the token is forgotten, and everything that came through it stays.
  def disconnect_question(connection)
    "Disconnect #{connection.provider_name}? Budgie forgets its sign-in and stops syncing. The Account, its bank transactions and what they were filed as stay."
  end
end
