module FilingRulesHelper
  # What a form's "sweep" box is read from: whether it's ticked. The box isn't an attribute of anything that's saved, so a form that has
  # one builds its field from this.
  SweepChoice = Data.define(:sweep)

  # What a rule does, in a sentence a person can check against what they meant, with how many bank transactions it has filed or ignored
  # and still has: "Spend from Groceries. In Chequing. Exactly -$82.45. 3 bank transactions filed or ignored." A rule whose envelope is
  # archived says it's inactive, in words.
  def filing_rule_detail(rule, count, budget)
    [ "#{rule.outcome_label}.",
      (rule.account ? "In #{rule.account.name}." : "Any account."),
      (rule.amount ? "Exactly #{money(rule.amount, budget: budget)}." : "Any amount."),
      (count.zero? ? "No bank transactions filed or ignored yet." : "#{pluralize(count, "bank transaction")} filed or ignored."),
      ("Inactive while its envelope is archived." if rule.inactive?) ].compact.join(" ")
  end
end
