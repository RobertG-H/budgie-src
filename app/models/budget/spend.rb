# Money paid out of the budget from one envelope, such as a grocery bill or the rent. An envelope's Spends in a month
# add up to its Spent. The rest, from its validations to its list order, is in DatedEnvelopeRecord.
class Budget::Spend < ApplicationRecord
  include DatedEnvelopeRecord

  belongs_to :envelope
end
