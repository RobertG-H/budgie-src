# What Budgie proposes for an unfiled bank transaction that no active Filing rule fits: the kind of record and the envelope that the
# Budget's similar bank transactions were filed as, and which one it was like, so that it can say why (ADR 0013). It's a value, worked
# out when it's shown and never stored, and it only suggests: nothing is created from it unless a person files the bank transaction.
#
# It's a Spend, a Refund or a Deposit, and never Ignore or an archived envelope. A Deposit has no envelope.
Budget::Guess = Data.define(:kind, :envelope_id, :envelope_name, :like) do
  # What the filing form starts as, in place of its own defaults: the kind and the envelope. See Budget::Filing::Draft.for.
  def draft_attributes
    { kind: kind, envelope_id: envelope_id }
  end

  # What the review for "File as guessed" sends back for it, so that what's filed is what was reviewed: "spend:5" or "refund:5", with the
  # envelope's id, or "deposit:", which has none.
  def review_value
    "#{kind}:#{envelope_id}"
  end

  # The same as `draft_attributes`, from what a review sent back (see `review_value`). Nothing is checked here: it's only what's asked for,
  # which Budget::Filing refuses if it isn't right.
  def self.draft_attributes_from(review_value)
    kind, envelope_id = review_value.to_s.split(":", 2)

    { kind: kind, envelope_id: envelope_id.presence }
  end

  # Where it would put the money, in the words a person uses: the envelope's name for a Spend, "Refund to Groceries" for a Refund, and
  # "Deposit" for a Deposit.
  def destination
    case kind
    when "spend" then envelope_name
    when "refund" then "Refund to #{envelope_name}"
    when "deposit" then "Deposit"
    end
  end

  # Why, in a line: "Guess: like LOBLAWS #1234 → Groceries", where the description is the bank transaction it was like, as the bank gave it.
  def label
    "Guess: like #{like} → #{destination}"
  end
end
