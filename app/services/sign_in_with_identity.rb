# Decides who an AuthProfile signs in as, creating the user on their first sign-in.
# Knows nothing about any particular identity provider.
class SignInWithIdentity
  Result = Data.define(:user, :failure_reason) do
    def success?
      failure_reason.nil?
    end
  end

  def self.call(profile)
    new(profile).call
  end

  def initialize(profile)
    @profile = profile
  end

  def call
    return failure(:unverified_email) unless verified_email?

    if (identity = Identity.find_by(provider: profile.provider, uid: profile.uid))
      success(refresh(identity))
    elsif User.exists?(email: profile.email)
      # Linking another identity to an existing user is a separate, deliberate feature.
      failure(:email_conflict)
    else
      create_invited_user
    end
  end

  private
    attr_reader :profile

    def verified_email?
      profile.email_verified == true && profile.email.present?
    end

    # User.email is left alone: it's set when the user is created and only changed deliberately.
    def refresh(identity)
      user = identity.user

      Identity.transaction do
        identity.update!(email: profile.email)
        user.update!(name: profile.name, avatar_url: profile.avatar_url)
      end

      user
    end

    # Only an email with a pending invite may create an account. The invite row is locked so it can't be
    # revoked, or accepted by a second sign-in, while the user is being created.
    def create_invited_user
      User.transaction do
        if (invite = Invite.pending.lock.find_by(email: profile.email))
          user = User.create!(email: profile.email, name: profile.name, avatar_url: profile.avatar_url)
          user.identities.create!(provider: profile.provider, uid: profile.uid, email: profile.email)
          invite.accept!(user)
          success(user)
        else
          failure(:not_invited)
        end
      end
    end

    def success(user)
      Result.new(user: user, failure_reason: nil)
    end

    def failure(reason)
      Result.new(user: nil, failure_reason: reason)
    end
end
