class User < ApplicationRecord
  # What the operator can turn on for a person, which they do from the Rails console on the host (there's no UI): `plaid` is connecting a bank through Plaid
  # (PlaidApi.available_to?). A new one is a name here and in the `users_features_known` check constraint.
  FEATURES = %w[ plaid ].freeze

  has_many :identities, dependent: :destroy
  has_many :sessions, dependent: :destroy
  # Deleting a user deletes their accepted invite too, so their email can be invited again.
  has_one :invite, dependent: :destroy
  has_one :budget, dependent: :destroy

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true
  validate :features_are_known

  # Whether `name` is turned on for them. A name that isn't one of FEATURES raises, as turning one on or off does, so a typo never quietly answers no.
  def feature?(name)
    features.include?(known_feature(name))
  end

  # Turns `name` on, as in `User.find_by!(email: "…").enable_feature!(:plaid)`, and is the same when it's already on.
  def enable_feature!(name)
    update!(features: features | [ known_feature(name) ])
  end

  # Turns `name` off, and is the same when it's already off. Nothing they made with it is changed.
  def disable_feature!(name)
    update!(features: features - [ known_feature(name) ])
  end

  private
    def known_feature(name)
      name = name.to_s
      raise ArgumentError, "#{name.inspect} isn't a feature. Choose one of: #{FEATURES.join(", ")}." unless FEATURES.include?(name)

      name
    end

    def features_are_known
      unknown = features - FEATURES
      errors.add(:features, "has #{unknown.join(", ")}, which #{unknown.one? ? "isn't a feature" : "aren't features"}") if unknown.any?
    end
end
