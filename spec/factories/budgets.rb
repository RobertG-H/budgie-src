FactoryBot.define do
  factory :budget do
    user
    currency { "CAD" }
  end

  factory :budget_envelope, class: "Budget::Envelope" do
    budget
    sequence(:name) { |n| "Envelope #{n}" }
    starting_balance { 0 }
  end

  factory :budget_deposit, class: "Budget::Deposit" do
    budget
    sequence(:description) { |n| "Deposit #{n}" }
    date { Date.new(2026, 9, 15) }
    month { date&.beginning_of_month }
    amount { 100 }
    notes { "" }
  end

  factory :budget_spend, class: "Budget::Spend" do
    association :envelope, factory: :budget_envelope
    sequence(:description) { |n| "Spend #{n}" }
    date { Date.new(2026, 9, 15) }
    amount { 100 }
    notes { "" }
  end

  factory :budget_refund, class: "Budget::Refund" do
    association :envelope, factory: :budget_envelope
    sequence(:description) { |n| "Refund #{n}" }
    date { Date.new(2026, 9, 15) }
    amount { 100 }
    notes { "" }
  end

  # Between two envelopes of one budget, unless given others.
  factory :budget_envelope_reallocation, class: "Budget::EnvelopeReallocation" do
    from_envelope { association :budget_envelope }
    to_envelope { association :budget_envelope, budget: from_envelope&.budget }
    sequence(:description) { |n| "Reallocation #{n}" }
    date { Date.new(2026, 9, 15) }
    amount { 100 }
    notes { "" }
  end

  factory :budget_ready_to_assign_reallocation, class: "Budget::ReadyToAssignReallocation" do
    association :envelope, factory: :budget_envelope
    sequence(:description) { |n| "Reallocation to Ready to Assign #{n}" }
    date { Date.new(2026, 9, 15) }
    amount { 100 }
    notes { "" }
  end

  factory :budget_assignment, class: "Budget::Assignment" do
    association :envelope, factory: :budget_envelope
    month { Date.new(2026, 9, 1) }
    amount { 100 }
  end

  # A signed amount in one column, which is how most banks lay out a download. The traits are the other two amount styles.
  factory :budget_csv_format, class: "Budget::CsvFormat" do
    budget
    sequence(:name) { |n| "CSV format #{n}" }
    rows_to_skip { 0 }
    column_count { 3 }
    date_column { 1 }
    date_format { "YYYY-MM-DD" }
    description_columns { [ 2 ] }
    amount_style { "signed" }
    amount_column { 3 }
    invert_sign { false }

    # Separate columns for money in and money out, as in: date, description, money out, money in.
    trait :in_and_out do
      column_count { 4 }
      amount_style { "in_and_out" }
      amount_column { nil }
      money_out_column { 3 }
      money_in_column { 4 }
    end

    # One unsigned amount and a column that says which way it went, as in: date, description, amount, direction.
    trait :direction do
      column_count { 4 }
      amount_style { "direction" }
      amount_column { 3 }
      direction_column { 4 }
      money_in_value { "Credit" }
    end
  end

  factory :budget_account, class: "Budget::Account" do
    budget
    sequence(:name) { |n| "Account #{n}" }
  end

  # Of an Account, with a CSV format of its budget unless given another. The file is gone, so only its name is kept.
  factory :budget_import, class: "Budget::Import" do
    association :account, factory: :budget_account
    csv_format { association :budget_csv_format, budget: account&.budget }
    sequence(:file_name) { |n| "import-#{n}.csv" }
    duplicates_skipped { 0 }
    zero_rows_skipped { 0 }
  end

  # Money out of $10 by default, which is the sign a Spend would be filed from, in the Account of its Import.
  factory :budget_bank_transaction, class: "Budget::BankTransaction" do
    account { association :budget_account }
    import { association :budget_import, account: account }
    sequence(:description) { |n| "Merchant #{n}" }
    date { Date.new(2026, 9, 15) }
    amount { -10 }

    # Filed as a Deposit when it's money in, and a Spend when it's money out, of its whole amount.
    trait :filed do
      after(:create) do |bank_transaction|
        create(bank_transaction.amount.positive? ? :budget_deposit_link : :budget_spend_link, bank_transaction: bank_transaction)
      end
    end

    trait :ignored do
      ignored_at { Time.zone.local(2026, 9, 16, 10) }
    end
  end

  # A standing instruction: bank transactions with its text in their description are filed as a Spend from an envelope of its budget
  # unless it says otherwise, with no Account or amount condition. The traits are the other outcomes.
  factory :budget_filing_rule, class: "Budget::FilingRule" do
    budget
    sequence(:text) { |n| "merchant #{n}" }
    outcome { "spend" }
    envelope { association :budget_envelope, budget: budget }

    trait :refund do
      outcome { "refund" }
    end

    trait :deposit do
      outcome { "deposit" }
      envelope { nil }
    end

    trait :ignore do
      outcome { "ignore" }
      envelope { nil }
    end
  end

  # The link between a bank transaction and the record it was filed as, with a record of the whole amount in the same budget
  # unless given another. A Deposit's is of money in, so its bank transaction is.
  factory :budget_deposit_link, class: "Budget::DepositLink" do
    bank_transaction { association :budget_bank_transaction, amount: 10 }
    deposit do
      association :budget_deposit, budget: bank_transaction.account.budget, date: bank_transaction.date, amount: bank_transaction.amount.abs
    end
  end

  factory :budget_spend_link, class: "Budget::SpendLink" do
    bank_transaction { association :budget_bank_transaction, amount: -10 }
    spend do
      association :budget_spend, envelope: association(:budget_envelope, budget: bank_transaction.account.budget), date: bank_transaction.date,
        amount: bank_transaction.amount.abs
    end
  end

  factory :budget_refund_link, class: "Budget::RefundLink" do
    bank_transaction { association :budget_bank_transaction, amount: 10 }
    refund do
      association :budget_refund, envelope: association(:budget_envelope, budget: bank_transaction.account.budget), date: bank_transaction.date,
        amount: bank_transaction.amount.abs
    end
  end
end
