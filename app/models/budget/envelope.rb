class Budget::Envelope < ApplicationRecord
  # decimal(15, 2) holds 13 digits before the decimal point.
  STARTING_BALANCE_LIMIT = 10**13

  belongs_to :budget

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false }
  validates :starting_balance, numericality: { greater_than: -STARTING_BALANCE_LIMIT, less_than: STARTING_BALANCE_LIMIT }
  validate :starting_balance_has_at_most_two_decimal_places

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }

  # A blank field means the envelope starts empty.
  def starting_balance=(value)
    super(value.presence || 0)
  end

  private
    # The column rounds to 2 places, so check what was entered before it's rounded.
    def starting_balance_has_at_most_two_decimal_places
      entered = BigDecimal(starting_balance_before_type_cast.to_s.strip, exception: false)
      return unless entered

      errors.add(:starting_balance, "can't have more than 2 decimal places") if entered.round(2) != entered
    end
end
