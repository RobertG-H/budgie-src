# Applies a budget's Filing rules to bank transactions: each one that a rule fits is filed the way the most specific rule that fits
# it says, or ignored, straight away and with no confirmation (ADR 0012). Filing goes through the same operation a person uses
# (Budget::Filing), so a rule's records are ordinary and editable (ADR 0004), and ignoring is what a person's Ignore does.
#
#   Budget::FilingRule::Applier.new(budget).apply(bank_transactions)   # => Result(filed: 3, ignored: 1)
#
# It's for the bank transactions that have just come in, which an Import creates, and for a sweep when a rule is saved. It never
# acts on one that's already filed or ignored: that's judged once their rows are locked, so one that was filed since it was looked at
# is left alone. Un-filing and un-ignoring never come here, or un-filing a row that a rule filed would file it again at once.
#
# The rules are loaded once, matching is in Ruby, and the records, the links, the note of which rule did it and the ignoring are each
# a statement for however many there are, so it makes the same number of queries for 10 bank transactions as for 1,000 and for 1
# rule as for 100.
class Budget::FilingRule::Applier
  Result = Data.define(:filed, :ignored)

  # `rules` are the budget's active rules, with their envelopes, which is all of them unless it's given others.
  def initialize(budget, rules: nil)
    @budget = budget
    @rules = rules || budget.filing_rules.active.to_a
    @matcher = Budget::FilingRule::Matcher.new(@rules)
  end

  attr_reader :rules

  # Each of the `bank_transactions` that a rule fits, with the rule that wins, as pairs. Nothing is changed. With `only`, just the ones
  # that rule wins, such as when it's a rule that was only just saved.
  def claims(bank_transactions, only: nil)
    bank_transactions.filter_map do |bank_transaction|
      rule = @matcher.rule_for(bank_transaction)
      [ bank_transaction, rule ] if rule && (only.nil? || rule == only)
    end
  end

  # Files or ignores every one that a rule fits, and says how many were filed and how many ignored, all in one database transaction.
  def apply(bank_transactions, only: nil)
    claims = claims(bank_transactions, only: only)
    return Result.new(filed: 0, ignored: 0) if claims.empty?

    Budget::BankTransaction.transaction do
      claims = still_unfiled(claims)
      to_ignore, to_file = claims.partition { |_, rule| rule.outcome == "ignore" }

      Result.new(filed: file(to_file), ignored: ignore(to_ignore))
    end
  end

  private
    # The claims whose bank transactions are still unfiled, which is only known once their rows are locked: the locks are held until
    # the database transaction ends, so nothing can file or ignore them in between.
    def still_unfiled(claims)
      ids = claims.map { |bank_transaction, _| bank_transaction.id }
      Budget::BankTransaction.where(id: ids).lock.pluck(:id)
      unfiled = Budget::BankTransaction.unfiled.where(id: ids).pluck(:id).to_set

      claims.select { |bank_transaction, _| unfiled.include?(bank_transaction.id) }
    end

    # Through the filing operation, as a person's filing is. A rule never fails the bank transactions that came in with it: if filing
    # one is refused, such as for an envelope that was archived since the rules were loaded, it's left unfiled for a person to do,
    # and the rest are filed. Each pass leaves out what the last one refused, so it ends.
    def file(claims)
      entries = claims.map do |bank_transaction, rule|
        Budget::Filing::Entry.new(bank_transaction: bank_transaction, filing_rule: rule,
          drafts: [ Budget::Filing::Draft.for(bank_transaction, kind: rule.outcome, envelope_id: rule.envelope_id) ])
      end
      filing = Budget::Filing.new(@budget)
      entries = entries.reject(&:refused?) until filing.file(entries)

      entries.size
    end

    def ignore(claims)
      Budget::BankTransaction.record_filing_rules(claims.to_h { |bank_transaction, rule| [ bank_transaction.id, rule.id ] }, ignored_at: Time.current)

      claims.size
    end
end
