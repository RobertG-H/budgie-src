FactoryBot.define do
  factory :invite do
    sequence(:email) { |n| "invitee#{n}@example.com" }

    trait :accepted do
      user { association :user, email: email }
      accepted_at { 1.day.ago }
    end

    trait :revoked do
      revoked_at { 1.day.ago }
    end
  end
end
