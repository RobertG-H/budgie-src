# A user's account at an identity provider, which is how they sign in.
class Identity < ApplicationRecord
  belongs_to :user

  validates :provider, :uid, :email, presence: true
  validates :uid, uniqueness: { scope: :provider }
end
