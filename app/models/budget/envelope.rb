class Budget::Envelope < ApplicationRecord
  belongs_to :budget

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false }
  validates :starting_balance, money: true

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }

  # A blank field means the envelope starts empty.
  def starting_balance=(value)
    super(value.presence || 0)
  end
end
