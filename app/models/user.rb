class User < ApplicationRecord
  has_many :identities, dependent: :destroy
  has_many :sessions, dependent: :destroy
  # Deleting a user deletes their accepted invite too, so their email can be invited again.
  has_one :invite, dependent: :destroy

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true
end
