# Where a budget's money is put aside for a purpose. Once it's finished with it can be archived, which keeps its history
# and takes it out of use: `archived_at` is null while it's in use, and the time it was archived otherwise, the way an
# Invite's status comes from its timestamps. See docs/adr/0008-an-archived-envelope-shows-only-where-it-has-figures.md.
class Budget::Envelope < ApplicationRecord
  # Raised when an envelope can't be archived; the message says what's wrong and what to do about it, for the person
  # who asked.
  class Refused < StandardError; end

  # What to do about an envelope that has money left, and about one that's Overspent, before archiving it.
  LOWER_IT = "Lower this month's Assigned, spend it or reallocate it first.".freeze
  RAISE_IT = "Assign more to it or reallocate money to it first.".freeze

  belongs_to :budget
  # An envelope with records can't be deleted: the model refuses with a reason, and the database's ON DELETE RESTRICT
  # is the backstop. Deleting the whole budget deletes the records first (see Budget).
  has_many :assignments, dependent: :restrict_with_error
  has_many :spends, dependent: :restrict_with_error
  has_many :refunds, dependent: :restrict_with_error
  # Money moved out of this envelope into another, and into this one from another.
  has_many :outgoing_reallocations, class_name: "Budget::EnvelopeReallocation", foreign_key: :from_envelope_id,
    inverse_of: :from_envelope, dependent: :restrict_with_error
  has_many :incoming_reallocations, class_name: "Budget::EnvelopeReallocation", foreign_key: :to_envelope_id,
    inverse_of: :to_envelope, dependent: :restrict_with_error
  # Money moved out of this envelope back into Ready to Assign.
  has_many :ready_to_assign_reallocations, class_name: "Budget::ReadyToAssignReallocation", inverse_of: :envelope,
    dependent: :restrict_with_error
  # The Filing rules that file into it. An envelope with no records can go, and takes its rules with it, which is why this stays
  # after the checks above that refuse when it has records.
  has_many :filing_rules, dependent: :destroy

  normalizes :name, with: ->(name) { name.squish }

  # Names are unique across archived envelopes too, which the database's index sees. The model tells the two apart so
  # that the error can say whose name it is.
  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false, conditions: -> { active } }
  validate :name_not_used_by_an_archived_envelope
  validates :starting_balance, money: true

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }
  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def archived?
    archived_at.present?
  end

  # Puts the envelope away, judged against today's month whichever month's page it's asked for from. It's refused, with
  # Refused and a message, unless its Available is 0 in the current month and nothing for it is dated after that month,
  # so nothing is left in an envelope that's put away. An envelope that's already archived stays as it is.
  #
  # It holds the budget's row lock, as starting a new month does, so the copy of last month's Assigned can't land on an
  # envelope as it's archived.
  def archive!
    budget.with_lock do
      reload
      next if archived?

      refuse_unless_ready_to_archive
      update!(archived_at: Time.current)
    end

    self
  end

  # Takes the envelope back into use. It has no precondition, and gives the envelope no Assigned: that's never there
  # without the person putting it there.
  def unarchive
    update!(archived_at: nil)
  end

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

  private
    def name_not_used_by_an_archived_envelope
      return if name.blank? || budget.nil?

      archived_namesakes = budget.envelopes.archived.where("lower(name) = ?", name.downcase).where.not(id: id)
      errors.add(:name, "is already used by an archived envelope. Unarchive it or choose another name.") if archived_namesakes.exists?
    end

    def refuse_unless_ready_to_archive
      month = Budget::Month.new(budget, Date.current)
      available = month.envelope_line(id).available
      raise Refused, "Available is #{money(available)} in #{month.name}. #{available.positive? ? LOWER_IT : RAISE_IT}" unless available.zero?
      raise Refused, "It has Assigned, Spends, Refunds or Reallocations after #{month.name}. Clear them first." if dated_after?(month)
    end

    # Whether anything is dated after the month: Assigned for a later month, or a Spend, a Refund or a Reallocation of
    # either kind, on either side, dated after the end of it.
    def dated_after?(month)
      assignments.where(month: month.next.date..).exists? ||
        [ spends, refunds, outgoing_reallocations, incoming_reallocations, ready_to_assign_reallocations ]
          .any? { |records| records.where(date: month.next.date..).exists? }
    end

    def money(amount)
      ActiveSupport::NumberHelper.number_to_currency(amount, unit: budget.currency_unit)
    end
end
