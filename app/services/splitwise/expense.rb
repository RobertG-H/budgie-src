# One Splitwise expense, as it concerns the person who signed in, and all that's kept of it. It's the value `Splitwise.client.expenses` answers with,
# so the sync (SyncSplitwise) never meets Splitwise's own JSON: every field of that is optional and unknown keys are ignored, so what's here is what could be read,
# and a field that couldn't is nil.
#
# - `id` is Splitwise's id for it, as a string. An expense with none is still here, so that a page is as long as Splitwise made it (a short page is how a sync
#   knows it has the last), but nothing could match it later, so the sync skips it.
# - `date` is the day Splitwise shows the person, which is the UTC date of the timestamp it sends. Splitwise stamps a day with midnight UTC
#   ("2026-10-01T00:00:00Z"), so converting to Eastern would move every expense to the evening before, and one on the 1st of a month into the month before.
# - `net_balance` is the person's own share, paid less owed, positive when friends owe them, as a BigDecimal (Splitwise sends money as a decimal string). It's nil
#   when the person isn't part of the expense, which is how a share of 0 differs from none: neither is stored.
# - `payment` is a settle-up, money paid between friends to settle what Splitwise says they owe.
# - `deleted_at` is set for an expense that was deleted: Splitwise keeps those in its listings, and can restore them.
Splitwise::Expense = Data.define(:id, :description, :date, :currency_code, :payment, :updated_at, :deleted_at, :net_balance) do
  # An expense from one entry of Splitwise's `expenses`, for the person with `user_id`. Nothing at all, when it's not a hash.
  def self.from_api(hash, user_id:)
    return unless hash.is_a?(Hash)

    new(id: hash["id"].presence&.to_s, description: hash["description"].presence&.to_s, date: timestamp(hash["date"])&.to_date, currency_code: hash["currency_code"].presence&.to_s,
      payment: hash["payment"] == true, updated_at: timestamp(hash["updated_at"]), deleted_at: timestamp(hash["deleted_at"]), net_balance: net_balance_of(hash["users"], user_id))
  end

  # The person's share, which is Splitwise's `net_balance` on their entry of `users`. It's found by the id on the entry, or on the user inside it, since Splitwise sends both.
  def self.net_balance_of(users, user_id)
    return unless users.is_a?(Array)

    share = users.find { |entry| entry.is_a?(Hash) && [ entry["user_id"], (entry["user"]["id"] if entry["user"].is_a?(Hash)) ].any? { |id| id.present? && id.to_s == user_id.to_s } }
    share && BigDecimal(share["net_balance"].to_s, exception: false)
  end

  # Splitwise sends timestamps as ISO 8601 in UTC. Anything else is nothing, not an error: the field is optional.
  def self.timestamp(value)
    Time.iso8601(value).utc if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  def deleted?
    deleted_at.present?
  end
end
