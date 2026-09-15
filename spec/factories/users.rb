FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "person#{n}@example.com" }
    name { "Robin Budgie" }
    avatar_url { "https://example.com/avatars/robin.png" }
  end
end
