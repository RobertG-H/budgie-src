# Money coming back for something spent from an envelope, such as a store refund, a friend paying you back or an
# insurance payout. It lands in the envelope, never in Ready to Assign, and an envelope's Refunds in a month add up
# to its Refunded. A Refund isn't linked to any particular Spend. The rest, from its validations to its list order,
# is in DatedEnvelopeRecord.
class Budget::Refund < ApplicationRecord
  include FiledFromBankTransaction
  include DatedEnvelopeRecord

  belongs_to :envelope
  # The bank transaction it was filed from, if one was.
  filed_from_bank_transaction "Budget::RefundLink"
  refuse_archived_envelopes :envelope
end
