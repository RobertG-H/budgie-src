# The bank transaction that a Spend was filed from, which is all there is to a Spend having come from one: the spends table has
# no import columns. It goes when the spend does, and the spend goes with it when the bank transaction is un-filed.
class Budget::SpendLink < ApplicationRecord
  include BankTransactionLink

  belongs_to :spend
end
