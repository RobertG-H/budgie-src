# Money moved out of one envelope into another on a date, such as covering an Overspent envelope or shifting what's left
# of one purpose to another. It lowers the From envelope's Available and raises the To envelope's by the same amount, and
# Ready to Assign doesn't change. The amount is always positive, because the two columns say which way the money moved.
# A Reallocation isn't linked to any Spend, Refund or Assigned amount, and nothing checks the From envelope's Available:
# like a Spend, it can leave it Overspent. The rest, from its validations to its list order, is in DatedEnvelopeRecord.
#
# It belongs to its budget through its From envelope, so it has no budget of its own. Both envelopes must be the same
# budget's, which no foreign key can say, so the model does. Money moving out to Ready to Assign is a different table.
class Budget::EnvelopeReallocation < ApplicationRecord
  include DatedEnvelopeRecord

  belongs_to :from_envelope, class_name: "Budget::Envelope", inverse_of: :outgoing_reallocations
  belongs_to :to_envelope, class_name: "Budget::Envelope", inverse_of: :incoming_reallocations

  validate :envelopes_differ
  validate :envelopes_in_the_same_budget

  # The Reallocations out of an envelope or into it.
  scope :involving, ->(envelope) { where(from_envelope: envelope).or(where(to_envelope: envelope)) }

  # Whether the money left `envelope`, as opposed to arriving in it.
  def outgoing_from?(envelope)
    from_envelope_id == envelope.id
  end

  # How the Reallocation reads on the page of one of its envelopes: "To Groceries" when the money left that envelope, and
  # "From Dining out" when it arrived there.
  def counterpart_for(envelope)
    outgoing_from?(envelope) ? "To #{to_envelope.name}" : "From #{from_envelope.name}"
  end

  # The amount from the side of one of its envelopes: negative when the money left it.
  def amount_for(envelope)
    outgoing_from?(envelope) ? -amount : amount
  end

  private
    def envelopes_differ
      errors.add(:to_envelope, "can't be the same envelope as From") if from_envelope && from_envelope == to_envelope
    end

    def envelopes_in_the_same_budget
      return unless from_envelope && to_envelope

      errors.add(:to_envelope, "must be in the same budget as From") if from_envelope.budget_id != to_envelope.budget_id
    end
end
