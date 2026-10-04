# What a Deposit, Spend or Refund has in common for having been filed from a bank transaction, which is all it says of where it came
# from: the table has no import columns (ADR 0002). The link is deleted with the record, which leaves that bank transaction unfiled
# when it was the last record.
#
#   filed_from_bank_transaction "Budget::SpendLink"
module FiledFromBankTransaction
  extend ActiveSupport::Concern

  class_methods do
    def filed_from_bank_transaction(link_class)
      has_one :bank_transaction_link, class_name: link_class, inverse_of: model_name.element.to_sym, dependent: :destroy
      has_one :bank_transaction, through: :bank_transaction_link
    end
  end
end
