# Permission for an email address to create a Budgie account. There's one row per email.
# created_at is when it was (last) invited, and its status is worked out from the timestamps.
class Invite < ApplicationRecord
  # Raised when an invite operation isn't allowed; the message is meant for the operator.
  class Refused < StandardError; end

  STATUSES = %w[ pending accepted revoked ].freeze

  belongs_to :user, optional: true

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }

  scope :pending, -> { where(accepted_at: nil, revoked_at: nil) }
  scope :accepted, -> { where.not(accepted_at: nil) }
  scope :revoked, -> { where(accepted_at: nil).where.not(revoked_at: nil) }

  class << self
    # Invites a new email, or invites a revoked one again. Sends the invite email.
    def issue!(email)
      invite = find_or_initialize_by(email: email)
      raise Refused, "#{invite.email} is already a user." if invite.accepted?
      raise Refused, "#{invite.email} already has a pending invite. Use invite:resend to send it again." if invite.persisted? && invite.pending?

      # Re-inviting a revoked email starts it over as a fresh invite.
      now = Time.current
      invite.update!(revoked_at: nil, created_at: now, updated_at: now)
      invite.deliver
    end

    def resend!(email)
      invite = find_by(email: email) or raise Refused, "#{normalize_value_for(:email, email)} hasn't been invited. Use invite:create."
      raise Refused, "#{invite.email}'s invite is #{invite.status}, so there's nothing to resend." unless invite.pending?

      invite.deliver
    end

    def revoke!(email)
      invite = find_by(email: email) or raise Refused, "#{normalize_value_for(:email, email)} hasn't been invited."
      invite.revoke!
    end
  end

  def status
    if accepted_at then "accepted"
    elsif revoked_at then "revoked"
    else "pending"
    end
  end

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end

  # Locks the row so a concurrent sign-in can't accept the invite while it's being revoked.
  def revoke!
    with_lock do
      raise Refused, "#{email}'s invite has already been accepted. Removing a user's access isn't supported yet." if accepted?
      raise Refused, "#{email}'s invite is already revoked." if revoked?

      update!(revoked_at: Time.current)
    end
    self
  end

  def accept!(user)
    update!(accepted_at: Time.current, user: user)
  end

  # Delivered immediately so the operator sees whether sending worked.
  def deliver
    InviteMailer.with(invite: self).invite.deliver_now
    self
  end
end
