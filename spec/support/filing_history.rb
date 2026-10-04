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

  # The rows numbered `numbers` of a file ("MERCHANT 3 17" and so on), imported and filed as Spends from `envelope` through the same
  # operations a person uses, which is far quicker than making them one at a time. For specs that count queries against a lot of history.
  def file_in_bulk(numbers, envelope)
    csv_format = budget.csv_formats.first || create(:budget_csv_format, budget: budget)
    rows = numbers.map { |n| "2026-01-15,MERCHANT #{n % 7} #{n},-10.00" }.join("\n")
    import = account.imports.build(csv_format: csv_format, file_name: "many.csv")
    expect(import.run(rows)).to be(true)

    entries = Budget::BankTransaction.where(import_id: import.id).map do |bank_transaction|
      Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: [ Budget::Filing::Draft.for(bank_transaction, envelope_id: envelope.id) ])
    end
    expect(Budget::Filing.new(budget).file(entries)).to be(true)
  end
end
