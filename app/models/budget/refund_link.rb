# The bank transaction that a Refund was filed from, which is all there is to a Refund having come from one: the refunds table has
# no import columns. It goes when the refund does, and the refund goes with it when the bank transaction is un-filed.
class Budget::RefundLink < ApplicationRecord
  include BankTransactionLink

  belongs_to :refund
end
