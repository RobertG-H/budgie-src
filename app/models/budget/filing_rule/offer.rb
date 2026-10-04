# The Filing rule that filing or ignoring a bank transaction by hand offers to make: "Always file like this". The text it would look for
# starts as the bank's whole description, normalised, and can be trimmed right there, and there's no Account or amount condition, which
# is for the Filing rules page. What it sets is what the person does: a Spend from an envelope, a Refund to one, a Deposit, or Ignore.
#
# The rule is made in the same database transaction as the filing or the ignoring, so that neither is done without the other. If a rule
# with identical conditions exists it's updated in place, and the form says so. A rule made from a bank transaction isn't what filed it:
# a person did, so the bank transaction has no rule noted, and a rule with overlapping but different text is just another rule.
#
# It can also sweep the other unfiled bank transactions the rule fits, in the same database transaction (Budget::FilingRule::Sweep), when
# that box is ticked as well: only the ones that went the same way as this one, so that an Ignore rule, which fits either, doesn't act on the
# others, and which the form says how many of as the text is edited.
#
#   offer = Budget::FilingRule::Offer.new(bank_transaction, budget: budget, make: true, text: "loblaws")
#   offer.file(entry)   # files it and makes the rule, or does neither and says why on `errors`
#   offer.ignore
#   offer.swept         # what the sweep filed and ignored, if it ran
class Budget::FilingRule::Offer
  include ActiveModel::Model
  include ActiveModel::Attributes

  # Whether the box is ticked, which it starts as, and the text the rule looks for, and whether the second box is, which also sweeps the
  # other unfiled bank transactions it fits.
  attribute :make, :boolean, default: true
  attribute :text, :string
  attribute :sweep, :boolean, default: true

  attr_reader :bank_transaction, :budget, :swept

  # `split` is for a form that holds more than one record, which never makes a rule.
  def initialize(bank_transaction, budget:, split: false, **attributes)
    @bank_transaction = bank_transaction
    @budget = budget
    @split = split
    super(**attributes)
    self.text = default_text if text.nil?
  end

  # Whether a rule is to be made: the box is ticked and the form isn't a split.
  def make?
    make && !@split
  end

  # A rule needs text of at least 3 characters, and the text is the bank's description until it's edited, so a shorter description has
  # none to offer.
  def available?
    default_text.length >= Budget::FilingRule::MIN_TEXT_LENGTH
  end

  # The bank's whole description, as it's matched.
  def default_text
    bank_transaction.normalized_description
  end

  # The rule with these conditions, which is only the text, since there's no Account or amount, if there is one. Saving updates it.
  def existing_rule
    budget.filing_rules.includes(:envelope).find_by(text: normalized_text, account_id: nil, amount: nil)
  end

  # Whether the text is one a rule can have, and part of the bank's description, so that there's a rule to say anything about.
  def valid_text?
    normalized_text.length >= Budget::FilingRule::MIN_TEXT_LENGTH && bank_transaction.normalized_description.include?(normalized_text)
  end

  # How many other unfiled bank transactions the rule would file or ignore if it were made as the text stands, as the form says before
  # it's saved. What it will be is only known once it's done, and it's the same for either: a Spend, a Refund, a Deposit or Ignore fit
  # the bank transactions that went the same way, which is all that's swept, so it's counted as the one that fits either.
  def sweep_count
    rule = existing_rule || Budget::FilingRule.new(budget: budget, text: normalized_text)
    rule.assign_attributes(outcome: "ignore", envelope: nil)

    Budget::FilingRule::Sweep.new(rule, like: bank_transaction).count
  end

  # Files the entry, which is one record, and makes the rule it says: what the person chose, and the text. True when both were done.
  def file(entry)
    draft = entry.drafts.sole

    perform(outcome: draft.kind, envelope_id: draft.envelope_id) { Budget::Filing.new(budget).file([ entry ]) }
  end

  # Ignores the bank transaction and makes an Ignore rule from the text. A bank transaction that can't be ignored raises
  # Budget::BankTransaction::Refused, as it does without a rule.
  def ignore
    perform(outcome: "ignore") do
      bank_transaction.ignore
      true
    end
  end

  private
    # Does what's asked and makes the rule, in one database transaction: if either fails, neither is done. What's wrong with the rule
    # is checked first, so that nothing is done for a text that's refused.
    def perform(outcome:, envelope_id: nil)
      errors.clear
      rule = build_rule(outcome: outcome, envelope_id: envelope_id)
      return false unless acceptable?(rule)

      done = false
      Budget::BankTransaction.transaction do
        done = yield && rule.save!
        raise ActiveRecord::Rollback unless done

        @swept = Budget::FilingRule::Sweep.new(rule, like: bank_transaction).run if sweep
      end

      done
    end

    # The rule that already has these conditions, changed to what's been done, or a new one.
    def build_rule(outcome:, envelope_id:)
      (existing_rule || Budget::FilingRule.new(budget: budget, text: normalized_text)).tap { |rule| rule.assign_attributes(outcome: outcome, envelope_id: envelope_id) }
    end

    # Its text has to be one a rule can have, and part of the bank's description, or it wouldn't fit the bank transaction it's made from.
    # Whatever else is wrong with the rule is wrong with what was filed, which says so itself.
    def acceptable?(rule)
      rule.valid?
      rule.errors[:text].each { |message| errors.add(:text, message) }
      errors.add(:text, "must be part of the bank transaction's description, so that the rule fits it") unless bank_transaction.normalized_description.include?(normalized_text)

      errors.empty?
    end

    def normalized_text
      Budget::FilingRule.normalize_value_for(:text, text.to_s)
    end
end
