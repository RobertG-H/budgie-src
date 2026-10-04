# Money paid out of the budget from one envelope, such as a grocery bill or the rent. An envelope's Spends in a month
# add up to its Spent. The rest, from its validations to its list order, is in DatedEnvelopeRecord.
class Budget::Spend < ApplicationRecord
  include FiledFromBankTransaction
  include DatedEnvelopeRecord

  belongs_to :envelope
  # The bank transaction it was filed from, if one was.
  filed_from_bank_transaction "Budget::SpendLink"
  refuse_archived_envelopes :envelope
end
