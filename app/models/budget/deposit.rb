class Budget::Deposit < ApplicationRecord
  belongs_to :budget
  # The bank transaction it was filed from, if one was. The link is deleted with it, which leaves that bank transaction unfiled
  # when it was the last record, and the table has no import columns (ADR 0002).
  has_one :bank_transaction_link, class_name: "Budget::DepositLink", inverse_of: :deposit, dependent: :destroy
  has_one :bank_transaction, through: :bank_transaction_link

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

  # The months a Deposit dated `date` can count toward: the month of its date, and the month after it, each as
  # the 1st. The database checks the same thing (budget_deposits_month_of_date_or_next).
  def self.months_for(date)
    this_month = date.beginning_of_month
    [ this_month, this_month.next_month ]
  end

  private
    # A Deposit counts toward the month of its date unless it's marked for the month after.
    def default_month
      self.month ||= date
    end

    def month_is_that_of_the_date_or_the_month_after
      return unless date && month

      this_month, next_month = self.class.months_for(date)
      return if [ this_month, next_month ].include?(month)

      errors.add(:month, "must be #{this_month.to_fs(:month_and_year)} or #{next_month.to_fs(:month_and_year)}")
    end
end
