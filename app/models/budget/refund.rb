# Money coming back for something spent from an envelope, such as a store refund, a friend paying you back or an
# insurance payout. It lands in the envelope, never in Ready to Assign, and an envelope's Refunds in a month add up
# to its Refunded. A Refund isn't linked to any particular Spend. It belongs to its budget through its envelope, so it
# has no budget of its own, and its behaviour never depends on its description.
class Budget::Refund < ApplicationRecord
  belongs_to :envelope

  normalizes :description, with: ->(description) { description.squish }
  # The column is NOT NULL, so notes left blank are saved as an empty string.
  normalizes :notes, with: ->(notes) { notes.to_s.strip }, apply_to_nil: true

  validates :description, presence: true
  validates :date, presence: true
  validates :amount, money: { positive: true }

  # The Refunds dated in a month, any day of which will do.
  scope :dated_in, ->(month) { where(date: month.beginning_of_month..month.end_of_month) }
  scope :newest_first, -> { order(date: :desc, created_at: :desc, id: :desc) }
end
