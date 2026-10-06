# Which of a budget's Filing rules a bank transaction fits, when it fits more than one: the most specific wins (see
# Budget::FilingRule#specificity). There's no ordering screen, so a rule's place is only ever what it says.
#
#   matcher = Budget::FilingRule::Matcher.for(budget)
#   matcher.rule_for(bank_transaction)
#
# A rule for an archived envelope, or pinned to an Account whose Filing rules are off, is skipped as if it didn't exist. And no rule wins for a bank
# transaction in an Account that has them off, whatever fits it, so what asks, an Import, a sweep or a Guess, only ever sees the rules that can act on
# it. The rules are sorted once, so that matching a long Import is a pass over them for each row, in Ruby, with no query per row.
class Budget::FilingRule::Matcher
  # The matcher for the budget's active rules, or for `rules` when it's given others, such as a sweep's. It also asks which of the budget's Accounts
  # have Filing rules off, which is one query whatever the rules and the bank transactions are, so what asks makes the same number of queries for any of them.
  def self.for(budget, rules: nil)
    new(rules || budget.filing_rules.active, accounts_without_filing_rules: budget.accounts.without_filing_rules.ids)
  end

  # `accounts_without_filing_rules` is the ids of the Accounts that have Filing rules off. It's required, so that a matcher made without asking can't forget them: `for` asks.
  def initialize(rules, accounts_without_filing_rules:)
    @rules = rules.reject(&:inactive?).sort_by(&:specificity).reverse
    @accounts_without_filing_rules = accounts_without_filing_rules.to_set
  end

  # The rule that wins for the bank transaction, or nothing when none fits or its Account has Filing rules off.
  def rule_for(bank_transaction)
    return if @accounts_without_filing_rules.include?(bank_transaction.account_id)

    @rules.find { |rule| rule.fits?(bank_transaction) }
  end
end
