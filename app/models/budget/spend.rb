# Money paid out of the budget from one envelope, such as a grocery bill or the rent. An envelope's Spends in a month
# add up to its Spent. The rest, from its validations to its list order, is in DatedEnvelopeRecord.
class Budget::Spend < ApplicationRecord
  include DatedEnvelopeRecord

  belongs_to :envelope
  # The bank transaction it was filed from, if one was. The link is deleted with it, which leaves that bank transaction unfiled
  # when it was the last record, and the table has no import columns (ADR 0002).
  has_one :bank_transaction_link, class_name: "Budget::SpendLink", inverse_of: :spend, dependent: :destroy
  has_one :bank_transaction, through: :bank_transaction_link
  refuse_archived_envelopes :envelope
end
