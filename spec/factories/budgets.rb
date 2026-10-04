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
end
