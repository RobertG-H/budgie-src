# A bank transaction and the drafts of the records it's to be filed as, which Filing takes. What's wrong with the bank transaction
# itself, such as that the records don't add up to it or that it's already filed, is on `errors`, and what's wrong with a record
# is on its draft.
class Budget::Filing::Entry
  include ActiveModel::Model

  attr_reader :bank_transaction, :drafts, :filing_rule

  # Each of `drafts` is a Draft, or what one is made from. `filing_rule` is the Filing rule that's filing it, if one is: a person's
  # filing has none.
  def initialize(bank_transaction:, drafts:, filing_rule: nil)
    @bank_transaction = bank_transaction
    @filing_rule = filing_rule
    @drafts = Array(drafts).map { |draft| draft.is_a?(Budget::Filing::Draft) ? draft : Budget::Filing::Draft.new(draft) }
  end

  # Whether anything is wrong with it, or with any record, so that it can't be filed.
  def refused?
    errors.any? || drafts.any? { |draft| draft.errors.any? }
  end

  # What the records add up to as they're entered, which only counts the ones that are figures, and what's left of the bank
  # transaction's amount, which is negative when they're over it. A form shows both as it goes.
  def total
    drafts.sum { |draft| BigDecimal(draft.amount.to_s, exception: false) || 0 }
  end

  def remaining
    bank_transaction.amount.abs - total
  end
end
