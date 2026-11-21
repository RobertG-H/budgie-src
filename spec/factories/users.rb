FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "person#{n}@example.com" }
    name { "Robin Budgie" }
    avatar_url { "https://example.com/avatars/robin.png" }

    # Past first-run setup, so pages other than setup can be visited.
    trait :with_budget do
      after(:create) { |user| create(:budget, user: user) }
    end

    # Can connect a bank through Plaid (PlaidApi.available_to?), which the operator turns on for a person.
    trait :plaid do
      features { [ "plaid" ] }
    end
  end
end
