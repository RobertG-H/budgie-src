FactoryBot.define do
  # A provider-neutral profile, as a provider mapper would build it.
  factory :auth_profile do
    skip_create
    initialize_with { new(**attributes) }

    provider { "example" }
    sequence(:uid) { |n| "uid-#{n}" }
    sequence(:email) { |n| "person#{n}@example.com" }
    email_verified { true }
    name { "Robin Budgie" }
    avatar_url { "https://example.com/avatars/robin.png" }
  end
end
