# Money coming back for something spent from an envelope, such as a store refund, a friend paying you back or an
# insurance payout. It lands in the envelope, never in Ready to Assign, and an envelope's Refunds in a month add up
# to its Refunded. A Refund isn't linked to any particular Spend. The rest, from its validations to its list order,
# is in DatedEnvelopeRecord.
class Budget::Refund < ApplicationRecord
  include DatedEnvelopeRecord

  belongs_to :envelope
  # The bank transaction it was filed from, if one was. The link is deleted with it, which leaves that bank transaction unfiled
  # when it was the last record, and the table has no import columns (ADR 0002).
  has_one :bank_transaction_link, class_name: "Budget::RefundLink", inverse_of: :refund, dependent: :destroy
  has_one :bank_transaction, through: :bank_transaction_link
  refuse_archived_envelopes :envelope
end
