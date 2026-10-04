class Budget::Deposit < ApplicationRecord
  belongs_to :budget

  normalizes :description, with: ->(description) { description.squish }
  normalizes :month, with: ->(month) { month.beginning_of_month }
  # The column is NOT NULL, so notes left blank are saved as an empty string.
  normalizes :notes, with: ->(notes) { notes.to_s.strip }, apply_to_nil: true

  before_validation :default_month

  validates :description, presence: true
  validates :date, presence: true
  validates :month, presence: true
  validates :amount, money: { positive: true }
  validate :month_is_that_of_the_date_or_the_month_after

  # The Deposits counting toward a month's Ready to Assign, which may include some dated in the month before.
  # Any day of the month will do: `month` is normalized to the 1st in queries too.
  scope :for_month, ->(month) { where(month: month) }
  scope :newest_first, -> { order(date: :desc, created_at: :desc, id: :desc) }

  private
    # A Deposit counts toward the month of its date unless it's marked for the month after.
    def default_month
      self.month ||= date
    end

    def month_is_that_of_the_date_or_the_month_after
      return unless date && month

      this_month = date.beginning_of_month
      next_month = this_month.next_month
      return if [ this_month, next_month ].include?(month)

      errors.add(:month, "must be #{this_month.strftime("%B %Y")} or #{next_month.strftime("%B %Y")}")
    end
end
