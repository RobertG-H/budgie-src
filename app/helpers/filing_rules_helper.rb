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

  # What's added to the question before deleting an envelope or an Account that has Filing rules, which are deleted with it: " Its 2 Filing rules
  # are deleted with it." Nothing when there are none, since nothing goes with it then.
  def filing_rules_deleted_with(envelope_or_account)
    count = envelope_or_account.filing_rules.count
    return "" if count.zero?

    " Its #{pluralize(count, "Filing rule")} #{count == 1 ? "is" : "are"} deleted with it."
  end

  # What "Always file like this" would do, in the muted line under it: "Bank transactions with 'loblaws' in their description are filed the same way as
  # they come in." The text is in a span of its own, which the sweep-preview controller keeps in step with the Text field as it's edited, so the
  # line says what the rule is whether or not "Edit rule" is open.
  def filing_rule_sentence(offer)
    safe_join([ "Bank transactions with '", content_tag(:span, offer.normalized_text, data: { sweep_preview_target: "echo" }), "' in their description are filed the same way as they come in." ])
  end

  # What a sweep would do, in two sentences: how many unfiled bank transactions the rule fits and would file or ignore, and, if there are some,
  # how many it fits but a more specific rule files, which aren't counted and shouldn't be taken for none. `others` is for the filing form, where
  # the bank transaction being filed isn't one of them. The second is nothing when there's nothing to say.
  def sweep_sentences(sweep, others:)
    count = sweep.count
    left = sweep.left_to_other_rules.size
    noun = ->(number) { "#{"other " if others}unfiled bank #{"transaction".pluralize(number)}" }
    fits = ->(number) { number == 1 ? "fits" : "fit" }
    but = ->(number) { "but a more specific Filing rule files #{number == 1 ? "it" : "them"}" }

    if count.zero? && left.zero?
      [ "No #{noun.(0)} fit.", nil ]
    elsif count.zero?
      [ "#{left} #{noun.(left)} #{fits.(left)}, #{but.(left)}.", nil ]
    else
      [ "#{count} #{noun.(count)} #{fits.(count)}.", (left.positive? ? "#{left} more #{fits.(left)}, #{but.(left)}." : nil) ]
    end
  end
end
