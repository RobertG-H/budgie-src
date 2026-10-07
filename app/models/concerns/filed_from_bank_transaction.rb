# What a Deposit, Spend or Refund has in common for having been filed from a bank transaction, which is all it says of where it came
# from: the table has no import columns (ADR 0002). The link is deleted with the record, which leaves that bank transaction unfiled
# when it was the last record. Saving an edit to one counts as a person having looked at what a Filing rule did with its bank transaction, so
# that is no longer to review (ADR 0017), wherever the edit was made: the Records page, an envelope's page or the month view.
#
#   filed_from_bank_transaction "Budget::SpendLink"
module FiledFromBankTransaction
  extend ActiveSupport::Concern

  class_methods do
    def filed_from_bank_transaction(link_class)
      has_one :bank_transaction_link, class_name: link_class, inverse_of: model_name.element.to_sym, dependent: :destroy
      has_one :bank_transaction, through: :bank_transaction_link

      after_update { mark_bank_transaction_reviewed(link_class) }
    end
  end

  private
    # One statement, with no bank transaction loaded: a record that wasn't filed from one finds none.
    def mark_bank_transaction_reviewed(link_class)
      links = link_class.constantize.where(self.class.model_name.element => id)
      Budget::BankTransaction.mark_reviewed(Budget::BankTransaction.where(id: links.select(:bank_transaction_id)))
    end
end
