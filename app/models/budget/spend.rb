# Money paid out of the budget from one envelope, such as a grocery bill or the rent. An envelope's Spends in a month
# add up to its Spent. A Spend belongs to its budget through its envelope, so it has no budget of its own, and its
# behaviour never depends on its description.
class Budget::Spend < ApplicationRecord
  belongs_to :envelope

  normalizes :description, with: ->(description) { description.squish }
  # The column is NOT NULL, so notes left blank are saved as an empty string.
  normalizes :notes, with: ->(notes) { notes.to_s.strip }, apply_to_nil: true

  validates :description, presence: true
  validates :date, presence: true
  validates :amount, money: { positive: true }

  # The Spends dated in a month, any day of which will do.
  scope :dated_in, ->(month) { where(date: month.beginning_of_month..month.end_of_month) }
  scope :newest_first, -> { order(date: :desc, created_at: :desc, id: :desc) }
end
