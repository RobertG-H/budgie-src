class Budget::Envelope < ApplicationRecord
  belongs_to :budget
  # An envelope with records can't be deleted: the model refuses with a reason, and the database's ON DELETE RESTRICT
  # is the backstop. Deleting the whole budget deletes the records first (see Budget).
  has_many :assignments, dependent: :restrict_with_error
  has_many :spends, dependent: :restrict_with_error

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false }
  validates :starting_balance, money: true

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }

  # A blank field means the envelope starts empty.
  def starting_balance=(value)
    super(value.presence || 0)
  end

  # Sets what's assigned to this envelope for `month`, any day of it, and returns that month's Assignment. A positive
  # amount creates the Assignment or changes it, and blank or 0 deletes it. When the amount is refused nothing changes
  # and the reasons are on the Assignment's `errors`.
  #
  # Submits for one envelope take turns on its row, so a double submit finds the Assignment the first one saved and
  # changes it, instead of failing on the unique index (or on the validation that checks it).
  def assign(month, amount)
    with_lock do
      assignments.find_or_initialize_by(month: month).tap { |assignment| assignment.assign(amount) }
    end
  end
end
