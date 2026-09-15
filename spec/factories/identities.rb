FactoryBot.define do
  factory :identity do
    user
    provider { "google_oauth2" }
    sequence(:uid) { |n| "10000000000#{n}" }
    email { user.email }
  end
end
