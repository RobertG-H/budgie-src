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
end
