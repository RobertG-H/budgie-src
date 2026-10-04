# What a Spend and a Refund have in common: a dated, described amount that belongs to one envelope, and to its budget
# through it, so it has no budget of its own. Its behaviour never depends on its description. A new table of records of
# this kind includes it.
module DatedEnvelopeRecord
  extend ActiveSupport::Concern

  included do
    belongs_to :envelope

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
end
