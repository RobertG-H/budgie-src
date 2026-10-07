# One record as it's asked for when filing a bank transaction: what a form sends for it, or what a Filing rule would. It's only
# what's asked: Filing makes the record from it, and what's wrong with the record is put on it, so a form can show it by the field.
# Nothing here is saved.
class Budget::Filing::Draft
  include ActiveModel::Model
  include ActiveModel::Attributes

  # The kind of record it is, by its table's name: a Deposit, a Spend or a Refund.
  attribute :kind, :string
  # What a form sends, which may be anything, so it's only read once it's looked up in the budget's own envelopes.
  attribute :envelope_id
  attribute :description, :string
  attribute :date, :date
  # The month a Deposit counts toward, which is its date's unless it's the month after. Only a Deposit has one.
  attribute :month, :date
  # Kept as it was sent, so that more than 2 decimal places can be refused and not rounded.
  attribute :amount
  attribute :notes, :string

  # The record Filing made of it, to insert.
  attr_accessor :record

  # How a bank transaction would be filed to start with: its date and description, and the whole of its amount as a positive
  # figure. Money out is a Spend and money in a Deposit, except money in from Splitwise, which is a Refund, since it's almost always
  # friends paying back a share (ADR 0016). Any of it can be told otherwise, which is how a Guess and a Filing rule take precedence.
  def self.for(bank_transaction, **attributes)
    # Its Account is only asked when the kind isn't told, so filing a lot with a rule's own kind makes no query for each.
    kind = attributes[:kind] || (bank_transaction.amount.positive? ? bank_transaction.account.money_in_kind : "spend")

    new({ description: bank_transaction.description, date: bank_transaction.date, amount: bank_transaction.amount.abs, notes: "" }.merge(attributes).merge(kind: kind))
  end

  # Whether anything the filing form keeps under "Edit details" differs from how the bank transaction starts: its description, date or amount isn't
  # the bank's own, a Deposit's month isn't its date's, or there are notes. A form that comes back refused with one of them changed has to show it.
  def edited_from?(bank_transaction)
    starting = self.class.for(bank_transaction)

    notes.present? || description != starting.description || date != starting.date ||
      BigDecimal(amount.to_s, exception: false) != starting.amount || (month.present? && month != bank_transaction.date.beginning_of_month)
  end

  # The record it asks for, not saved. An envelope that isn't one of the `envelopes`, which are the budget's own and by id, is no
  # envelope, which the record refuses: another budget's, or one that doesn't exist, can't be filed into.
  def build_record(budget, envelopes)
    shared = { description: description, date: date, amount: amount, notes: notes }

    case kind
    when "deposit" then Budget::Deposit.new(budget: budget, month: month, **shared)
    when "spend" then Budget::Spend.new(envelope: envelope_in(envelopes), **shared)
    when "refund" then Budget::Refund.new(envelope: envelope_in(envelopes), **shared)
    end
  end

  # What was wrong with the record, which is on the field of the form that it was entered in.
  def copy_errors_from(record)
    record.errors.each { |error| errors.add(error.attribute == :envelope ? :envelope_id : error.attribute, error.message) }
  end

  private
    def envelope_in(envelopes)
      envelopes[Integer(envelope_id.to_s, 10, exception: false)]
    end
end
