# When a bank says a bank transaction it synced was authorised, which can be days before the date it posted on (the bank transaction's `date`). Only a
# bank's sync through Plaid writes it, and nothing reads it yet: it's kept for recognising a bank transaction a CSV file brought in as the same one a
# sync brought in (#146), since a bank's CSV may use either date. Null for every other bank transaction, and for one the bank gave no date for.
class AddAuthorizedDateToBudgetBankTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :budget_bank_transactions, :authorized_date, :date
  end
end
