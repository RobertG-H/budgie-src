module FilingRulesHelper
  # What a form's "sweep" box is read from: whether it's ticked. The box isn't an attribute of anything that's saved, so a form that has
  # one builds its field from this.
  SweepChoice = Data.define(:sweep)

  # The question before deleting a Filing rule from the list, which names it and says what's kept, with how many bank transactions it filed or ignored
  # that still are: "Delete the Filing rule for 'loblaws'? The 3 bank transactions it filed or ignored stay as they are." Deleting never changes them, and
  # with none there's nothing to say.
  def filing_rule_delete_question(rule, count)
    question = "Delete the Filing rule for '#{rule.text}'?"

    case count
    when 0 then question
    when 1 then "#{question} The bank transaction it filed or ignored stays as it is."
    else "#{question} The #{count} bank transactions it filed or ignored stay as they are."
    end
  end

  # What's added to the question before deleting an envelope or an Account that has Filing rules, which are deleted with it: " Its 2 Filing rules
  # are deleted with it." Nothing when there are none, since nothing goes with it then.
  def filing_rules_deleted_with(envelope_or_account)
    count = envelope_or_account.filing_rules.count
    return "" if count.zero?

    " Its #{pluralize(count, "Filing rule")} #{count == 1 ? "is" : "are"} deleted with it."
  end

  # What "Always file like this" would do, in the muted line under it, which says which Account it's for: "Chequing bank transactions with 'loblaws' in their
  # description are filed the same way as they come in." or "Bank transactions in any account with 'loblaws' in their description are filed the same way
  # as they come in." Both are there and the one that doesn't apply is hidden, since the sweep-preview controller changes it when the other Account choice is
  # made, and keeps the text, which is in a span of its own, in step with the Text field as it's edited, so the line says what the rule is whether or not
  # "Edit rule" is open.
  def filing_rule_sentence(offer)
    echo = -> { content_tag(:span, offer.normalized_text, data: { sweep_preview_target: "echo" }) }
    ending = "' in their description are filed the same way as they come in."

    safe_join([
      content_tag(:span, safe_join([ "#{offer.bank_transaction.account.name} bank transactions with '", echo.call, ending ]), hidden: !offer.pinned?,
        data: { sweep_preview_target: "variant", variant: "pinned" }),
      content_tag(:span, safe_join([ "Bank transactions in any account with '", echo.call, ending ]), hidden: offer.pinned?,
        data: { sweep_preview_target: "variant", variant: "any" })
    ])
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
