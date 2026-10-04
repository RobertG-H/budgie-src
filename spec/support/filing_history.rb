# The history a Guess is worked out from, for specs that need some: bank transactions filed as one record, and one still to file. Include
# it in a group that has `budget` and `account` (a `let` each), such as `include FilingHistory`.
module FilingHistory
  # A bank transaction that was filed as one record, the way a person files it: money out as a Spend from `envelope`, money in as a
  # Deposit, or as a Refund to `envelope` when one is given.
  def filed(description, envelope = nil, amount: -50, date: Date.new(2026, 9, 10), account: self.account)
    bank_transaction = create(:budget_bank_transaction, account: account, description: description, amount: amount, date: date)
    record_attributes = { date: date, amount: amount.abs }

    if amount.negative?
      create(:budget_spend_link, bank_transaction: bank_transaction, spend: create(:budget_spend, envelope: envelope, **record_attributes))
    elsif envelope
      create(:budget_refund_link, bank_transaction: bank_transaction, refund: create(:budget_refund, envelope: envelope, **record_attributes))
    else
      create(:budget_deposit_link, bank_transaction: bank_transaction, deposit: create(:budget_deposit, budget: budget, **record_attributes))
    end

    bank_transaction
  end

  # A bank transaction that's still to file, as it's read back, which is what a Guess is worked out from: the database works out the
  # normalised description.
  def unfiled(description, amount: -20, date: Date.new(2026, 10, 2), account: self.account)
    create(:budget_bank_transaction, account: account, description: description, amount: amount, date: date).reload
  end
end
