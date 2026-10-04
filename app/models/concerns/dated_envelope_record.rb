# What the records of an envelope's money have in common: a dated, described, positive amount. Its behaviour never
# depends on its description. A Spend and a Refund belong to one envelope, and to its budget through it, so they have no
# budget of their own; a Reallocation is between two, or one and Ready to Assign. A new table of records of this kind includes this and declares the
# envelope or envelopes it belongs to.
module DatedEnvelopeRecord
  extend ActiveSupport::Concern

  included do
    normalizes :description, with: ->(description) { description.squish }
    # The column is NOT NULL, so notes left blank are saved as an empty string.
    normalizes :notes, with: ->(notes) { notes.to_s.strip }, apply_to_nil: true

    validates :description, presence: true
    validates :date, presence: true
    validates :amount, money: { positive: true }

    # The records dated in a month, any day of which will do.
    scope :dated_in, ->(month) { where(date: month.beginning_of_month..month.end_of_month) }
    scope :newest_first, -> { order(date: :desc, created_at: :desc, id: :desc) }
  end

  class_methods do
    # An archived envelope takes no new records, so one can't be added to it, and a record can't be moved into one. A
    # record that's already in an archived envelope stays as it is, and can still be changed and deleted. Each of
    # `associations` is an envelope the record belongs to.
    def refuse_archived_envelopes(*associations)
      validate do
        associations.each do |association|
          next unless public_send(association)&.archived?

          errors.add(association, "is archived") if new_record? || public_send(:"#{association}_id_changed?")
        end
      end
    end
  end
end
