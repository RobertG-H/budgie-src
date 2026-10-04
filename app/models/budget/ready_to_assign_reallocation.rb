# Money moved out of one envelope back into Ready to Assign on a date, such as what's left of a holiday once it's over.
# It lowers the envelope's Available and raises Ready to Assign by the same amount, from the month of its date: unlike a
# Deposit it has no month of its own to choose, since the money is already in hand. The amount is always positive.
# Money going the other way, from Ready to Assign into an envelope, is Assigned, never a Reallocation. Nothing checks the
# envelope's Available, so, like a Spend, it can leave it Overspent. The rest, from its validations to its list order, is
# in DatedEnvelopeRecord.
#
# It belongs to its budget through its envelope, so it has no budget of its own. The envelope is the form's From.
class Budget::ReadyToAssignReallocation < ApplicationRecord
  include DatedEnvelopeRecord

  belongs_to :envelope, inverse_of: :ready_to_assign_reallocations
  refuse_archived_envelopes :envelope

  # The form's From, which a Reallocation to an envelope calls its From envelope.
  alias_attribute :from_envelope_id, :envelope_id

  # The envelope ids the Reallocation is in or out of in the database, From first. A refused change isn't saved, so
  # these are what the Reallocation is, not what was sent.
  def envelope_ids_in_database
    [ envelope_id_in_database ]
  end

  # How the Reallocation reads on the page of its envelope, which is the only one it's listed on.
  def counterpart_for(_envelope)
    "To Ready to Assign"
  end

  # The amount from the side of its envelope: always negative, since the money left it.
  def amount_for(_envelope)
    -amount
  end
end
