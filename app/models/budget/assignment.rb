# Money moved from Ready to Assign into one envelope for one month: that envelope's Assigned in that month. It's one
# figure per envelope per month, edited in place, so there's no Assignment of nothing: to assign nothing, delete it.
class Budget::Assignment < ApplicationRecord
  belongs_to :envelope

  normalizes :month, with: ->(month) { month.beginning_of_month }

  validates :month, presence: true
  validates :month, uniqueness: { scope: :envelope_id }, allow_nil: true
  validates :amount, money: { positive: true }

  # Saves `amount` as what's assigned. Blank or 0, which is to assign nothing, deletes this Assignment instead, since
  # there's no Assignment of nothing. When the amount is refused nothing changes, and the reasons are in `errors`.
  def assign(amount)
    self.amount = amount

    if assigns_nothing?
      destroy if persisted?
    else
      save
    end
  end

  private
    # Blank or 0, judged on what was entered: once it's a decimal, a word that isn't a number reads as 0 too.
    def assigns_nothing?
      entered = amount_before_type_cast.to_s.strip
      entered.empty? || BigDecimal(entered, exception: false)&.zero?
    end
end
