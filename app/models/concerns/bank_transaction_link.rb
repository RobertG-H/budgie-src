# What the three link tables have in common: a link says that a bank transaction was filed as one record, and holds both. A
# record comes from at most one bank transaction, which a unique index on it says, and a bank transaction can have several records.
# The core tables stay free of import columns (ADR 0002): everything about where a record came from is here.
module BankTransactionLink
  extend ActiveSupport::Concern

  included do
    belongs_to :bank_transaction, class_name: "Budget::BankTransaction"

    validate :bank_transaction_is_not_ignored
  end

  private
    # An ignored bank transaction isn't filed, and a filed one isn't ignored, so a link can't be made to one that's ignored.
    def bank_transaction_is_not_ignored
      errors.add(:bank_transaction, "is ignored, so it can't be filed") if bank_transaction&.ignored?
    end
end
