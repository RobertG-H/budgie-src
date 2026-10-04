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
end
