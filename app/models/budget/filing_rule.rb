# A standing instruction, such as "anything from Loblaws goes to Groceries": when an Import creates a bank transaction that it fits,
# Budgie files it the way the rule says, straight away and through the same filing operation a person uses, or ignores it
# (ADR 0012). It never changes what is already filed or ignored.
#
# It fits a bank transaction by the description (the rule's text is contained in it) and, if it has them, by Account and by an
# exact amount. It sets one outcome for the whole amount: a Spend from an envelope, a Refund to one, a Deposit, or Ignore. There are
# no splits, and nothing else is set: the record's description is the bank's, and a Deposit's month is its date's.
#
# It belongs to its budget and never to a user. It has no stored "active" flag: it's inactive while its envelope is archived, and
# active again once it's unarchived. Filing never writes to it, so `updated_at` is when it was last edited, which is one of the
# things that decides which of several rules wins (see `specificity`).
class Budget::FilingRule < ApplicationRecord
  OUTCOMES = %w[ spend refund deposit ignore ].freeze
  # A shorter text would fit nearly everything.
  MIN_TEXT_LENGTH = 3
  # What's said when two saves of the same conditions race: the validation looks for the other rule before it's saved, so only the unique index
  # sees it.
  SAVED_A_MOMENT_AGO = "Another Filing rule with the same text, Account and amount was saved a moment ago. Try again.".freeze

  belongs_to :budget
  # Nobody has to be pinned: a rule with no Account fits every Account, and one with no amount fits every amount.
  belongs_to :account, optional: true
  belongs_to :envelope, optional: true
  # What it filed or ignored. Deleting the rule leaves them as they are, only with no rule to say which one did it.
  has_many :bank_transactions, dependent: :nullify

  # The way a bank transaction's description is for matching (ADR 0010), so that "LOBLAWS  #1234" is text a description has.
  normalizes :text, with: ->(text) { Budget::BankTransaction.normalize_description(text) }

  before_validation :leave_out_envelope_that_the_outcome_has_none_of

  validates :text, presence: true, length: { minimum: MIN_TEXT_LENGTH }
  validates :outcome, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }, allow_blank: true
  # The money rule is for an amount that's there: a rule without one fits any amount.
  validates :amount, money: true, if: -> { amount_before_type_cast.present? }
  validate :amount_is_not_zero
  validate :amount_suits_the_outcome
  validate :account_is_in_the_budget
  validate :envelope_suits_the_outcome
  validate :envelope_is_not_archived
  validate :conditions_are_not_another_rules

  # What the sweep did when it was saved with one (see #save_and_sweep): a Budget::FilingRule::Applier::Result.
  attr_reader :swept

  scope :alphabetical_by_text, -> { order(:text, :id) }
  # The rules that act: those that aren't for an archived envelope. A rule with no envelope has none to be archived. The envelopes come
  # with them, so that asking one whether it's inactive costs nothing.
  scope :active, -> { eager_load(:envelope).where(budget_envelopes: { archived_at: nil }) }

  # Saves it, and files and ignores the unfiled bank transactions it now fits if `sweep`, in one database transaction: when either fails,
  # neither is done. What the sweep did is `swept`. Two saves of the same conditions can race, which only the unique index sees, and the
  # loser is told so like any other refusal.
  def save_and_sweep(sweep: false)
    transaction do
      saved = save
      @swept = Budget::FilingRule::Sweep.new(self).run if saved && sweep
      saved
    end
  rescue ActiveRecord::RecordNotUnique
    errors.add(:base, SAVED_A_MOMENT_AGO)
    false
  end

  # Whether it does nothing for now, because its envelope is archived.
  def inactive?
    envelope&.archived? || false
  end

  # What it does, in the words a person uses: "Spend from Groceries", "Refund to Groceries", "Deposit" or "Ignore".
  def outcome_label
    case outcome
    when "spend" then "Spend from #{envelope&.name}"
    when "refund" then "Refund to #{envelope&.name}"
    when "deposit" then "Deposit"
    when "ignore" then "Ignore"
    end
  end

  # What it does with the bank transactions it fits, as a phrase to follow "it" or "which": "files them as Spend from Groceries" or "ignores them".
  def effect
    outcome == "ignore" ? "ignores them" : "files them as #{outcome_label}"
  end

  # A Spend or a Refund goes to an envelope, and a Deposit or Ignore doesn't.
  def needs_envelope?
    %w[ spend refund ].include?(outcome)
  end

  # Whether the bank transaction is one it files or ignores: its description contains the text, it's in the rule's Account if the rule
  # has one, its amount is the rule's if the rule has one, and its sign suits the outcome. It's only about the bank transaction's own
  # figures: whether it's already filed or ignored, and whether the rule is inactive, are for what asks. The description is read the way
  # the text is, in Ruby, so they can't disagree.
  def fits?(bank_transaction)
    suits_money?(bank_transaction.amount) &&
      (account_id.nil? || account_id == bank_transaction.account_id) &&
      (amount.nil? || amount == bank_transaction.amount) &&
      bank_transaction.description_for_matching.include?(text)
  end

  # How specific it is, to compare with another's: an exact amount beats none, then a pinned Account beats any Account, then longer
  # text, then the most recently edited, and the newer rule last, so that the order is total. Greater is more specific. A rule
  # that's changed and not yet saved counts as edited now, which is what saving it will make it.
  def specificity
    [ amount.nil? ? 0 : 1, account_id.nil? ? 0 : 1, text.length, (changed? ? Time.current : updated_at), id || Float::INFINITY ]
  end

  private
    # A Spend fits money out, a Refund and a Deposit fit money in, and Ignore fits either.
    def suits_money?(bank_transaction_amount)
      case outcome
      when "spend" then bank_transaction_amount.negative?
      when "refund", "deposit" then bank_transaction_amount.positive?
      else true
      end
    end

    # A Deposit and Ignore have no envelope, which the table says too, so one that a form sends along with them is left out.
    def leave_out_envelope_that_the_outcome_has_none_of
      self.envelope = nil unless needs_envelope?
    end

    def amount_is_not_zero
      errors.add(:amount, "must be other than 0") if amount&.zero? && !errors.include?(:amount)
    end

    # A Spend is money out, which is negative, and a Refund and a Deposit are money in. Ignore fits either.
    def amount_suits_the_outcome
      return if amount.nil? || amount.zero? || errors.include?(:amount)

      case outcome
      when "spend" then errors.add(:amount, "must be negative, since a Spend is money out") if amount.positive?
      when "refund", "deposit" then errors.add(:amount, "must be positive, since a #{outcome.capitalize} is money in") if amount.negative?
      end
    end

    # Which budget an Account is in is up to the model: no foreign key can say. Another budget's, or one that doesn't exist, is no
    # Account of this one's.
    def account_is_in_the_budget
      errors.add(:account, "isn't one of this budget's") if (account_id || account) && account&.budget_id != budget_id
    end

    def envelope_suits_the_outcome
      if envelope_id || envelope
        errors.add(:envelope, "isn't one of this budget's") unless envelope&.budget_id == budget_id
      elsif needs_envelope?
        errors.add(:envelope, "can't be blank")
      end
    end

    # An archived envelope takes nothing new, so a rule can't be made for one or moved to one. A rule that's already for one stays as
    # it is, inactive, and can still be edited.
    def envelope_is_not_archived
      errors.add(:envelope, "is archived") if envelope&.archived? && (new_record? || envelope_id_changed?)
    end

    # Two rules never have identical conditions, which the unique index says too. This one says which rule it is.
    def conditions_are_not_another_rules
      return if text.blank? || budget.nil?

      other = budget.filing_rules.where.not(id: id).includes(:envelope).find_by(text: text, account_id: account_id, amount: amount)
      return unless other

      errors.add(:base, "Another Filing rule already has the same text, Account and amount. It #{other.effect}.")
    end
end
