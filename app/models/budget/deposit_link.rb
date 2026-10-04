# The bank transaction that a Deposit was filed from, which is all there is to a Deposit having come from one: the deposits table has
# no import columns. It goes when the deposit does, and the deposit goes with it when the bank transaction is un-filed.
class Budget::DepositLink < ApplicationRecord
  include BankTransactionLink

  belongs_to :deposit
end
