# What saving a Filing rule can do to the unfiled bank transactions that are already there: file or ignore the ones it fits the way it
# says, so that a rule made after an Import tidies that Import up too. It's the same thing an Import does to the rows it brings in, so it
# goes through the same Applier, and it only ever sees bank transactions that are unfiled: a filed or ignored one is never touched
# (ADR 0002), and it never runs on un-filing, un-ignoring or editing one.
#
#   sweep = Budget::FilingRule::Sweep.new(rule)
#   sweep.count   # how many it would file or ignore, as a form says before it's saved
#   sweep.run     # files and ignores them, and says how many
#
# Which ones are those where this rule is the one that wins, among the budget's active rules, and not every one that it fits: a bank
# transaction that a more specific rule fits is that rule's, as it would have been in an Import. The rule can be new, or changed and not yet
# saved, which is how a form counts what saving it would do: it replaces its saved self, and counts as edited now.
#
# An Account that has Filing rules off (`files_with_rules`) has every bank transaction wait for a person, so a sweep leaves its bank transactions out of what it
# files, what it counts and what it says a more specific rule files, whichever rule is being saved. A rule pinned to one is inactive, so it sweeps nothing.
#
# `made_from` is the bank transaction a rule is being made from by hand: it's left out, being the one that's just been done, and only bank
# transactions that went the same way (money in, or money out) are swept, so that an Ignore rule that fits either doesn't act on the other
# way's bank transactions, which the person wasn't looking at.
#
# It makes the same number of queries however many bank transactions it files.
class Budget::FilingRule::Sweep
  def initialize(rule, made_from: nil)
    @rule = rule
    @made_from = made_from
  end

  # The bank transactions it would file or ignore.
  def bank_transactions
    @bank_transactions ||= applier.claims(candidates, only: @rule).map(&:bank_transaction)
  end

  def count
    bank_transactions.size
  end

  # The unfiled bank transactions the rule fits but a more specific rule is the one to file, which a sweep leaves to that rule. They aren't in
  # `bank_transactions`, so a form says why they aren't counted, which "No other unfiled bank transactions fit" wouldn't.
  def left_to_other_rules
    @left_to_other_rules ||= @rule.inactive? ? [] : candidates.select { |bank_transaction| @rule.fits?(bank_transaction) } - bank_transactions
  end

  # Files and ignores them, in one database transaction, and says how many (a Budget::FilingRule::Applier::Result).
  def run
    applier.apply(candidates, only: @rule)
  end

  private
    def budget
      @rule.budget
    end

    # The budget's active rules, with this one in place of its saved self.
    def applier
      @applier ||= Budget::FilingRule::Applier.new(budget, rules: budget.filing_rules.active.where.not(id: @rule.id).to_a + [ @rule ])
    end

    def candidates
      @candidates ||= begin
        unfiled = budget.bank_transactions.unfiled.merge(Budget::Account.with_filing_rules)
        if @made_from
          same_way = @made_from.amount.positive? ? Budget::BankTransaction.money_in : Budget::BankTransaction.money_out
          unfiled = unfiled.where.not(id: @made_from.id).merge(same_way)
        end
        unfiled.to_a
      end
    end
end
