module PlaidChoicesHelper
  # The options of a choice's "Becomes" select (plaid_choices/_choice): A new Account, then each Account it can link onto, in a group of their own and only when
  # there are any, each carrying the date it starts reading from for the plaid-choice controller, then Leave out, with the choice's own selected.
  def plaid_choice_options(choice)
    selected = choice.becomes
    targets = choice.targets.map do |target|
      [ target.name, ConnectPlaid::Choice.link_value(target.id), { data: { read_from: target.read_from&.iso8601 } } ]
    end

    safe_join([
      options_for_select([ [ "A new Account", ConnectPlaid::Choice::NEW ] ], selected),
      (tag.optgroup(options_for_select(targets, selected), label: "Link onto an existing Account") if targets.any?),
      options_for_select([ [ "Leave out", ConnectPlaid::Choice::LEAVE ] ], selected)
    ].compact)
  end
end
