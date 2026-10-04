# Which of a budget's Filing rules a bank transaction fits, when it fits more than one: the most specific wins (see
# Budget::FilingRule#specificity). There's no ordering screen, so a rule's place is only ever what it says.
#
#   matcher = Budget::FilingRule::Matcher.new(budget.filing_rules.active)
#   matcher.rule_for(bank_transaction)
#
# A rule for an archived envelope is skipped as if it didn't exist. The rules are sorted once, so that matching a long Import is a
# pass over them for each row, in Ruby, with no query per row.
class Budget::FilingRule::Matcher
  def initialize(rules)
    @rules = rules.reject(&:inactive?).sort_by(&:specificity).reverse
  end

  # The rule that wins for the bank transaction, or nothing when none fits.
  def rule_for(bank_transaction)
    @rules.find { |rule| rule.fits?(bank_transaction) }
  end
end
