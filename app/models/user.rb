class User < ApplicationRecord
  has_many :identities, dependent: :destroy
  has_many :sessions, dependent: :destroy

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true
end
