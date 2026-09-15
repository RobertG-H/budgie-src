require "rails_helper"

RSpec.describe SignInWithIdentity do
  def sign_in(profile)
    described_class.call(profile)
  end

  def record_counts
    [ User.count, Identity.count ]
  end

  context "when the provider hasn't verified the email" do
    it "refuses and creates nothing" do
      result = nil

      expect { result = sign_in(build(:auth_profile, email_verified: false)) }.not_to change { record_counts }
      expect(result).not_to be_success
      expect(result).to have_attributes(user: nil, failure_reason: :unverified_email)
    end

    it "refuses a known identity too" do
      identity = create(:identity, provider: "example")
      profile = build(:auth_profile, provider: "example", uid: identity.uid, email_verified: false)

      expect(sign_in(profile).failure_reason).to eq(:unverified_email)
    end

    it "refuses a profile without an email" do
      expect(sign_in(build(:auth_profile, email: nil)).failure_reason).to eq(:unverified_email)
    end
  end

  context "with a known identity" do
    let(:identity) { create(:identity, provider: "example", email: "old@example.com") }
    let(:user) { identity.user }

    it "signs in that identity's user" do
      result = sign_in(build(:auth_profile, provider: "example", uid: identity.uid))

      expect(result).to be_success
      expect(result.user).to eq(user)
    end

    it "refreshes the identity's email and the user's name and avatar, but not the user's email" do
      profile = build(:auth_profile,
        provider: "example", uid: identity.uid,
        email: "new@example.com", name: "Robin Renamed", avatar_url: "https://example.com/avatars/new.png")

      expect { sign_in(profile) }.not_to change { user.reload.email }
      expect(identity.reload.email).to eq("new@example.com")
      expect(user).to have_attributes(name: "Robin Renamed", avatar_url: "https://example.com/avatars/new.png")
    end

    it "signs in even when the provider's email now belongs to another user" do
      other_user = create(:user)

      result = sign_in(build(:auth_profile, provider: "example", uid: identity.uid, email: other_user.email))

      expect(result.user).to eq(user)
    end

    it "creates nothing" do
      identity

      expect { sign_in(build(:auth_profile, provider: "example", uid: identity.uid)) }.not_to change { record_counts }
    end
  end

  context "with an unknown identity whose email belongs to an existing user" do
    it "refuses and creates nothing" do
      create(:user, email: "robin@example.com")
      result = nil

      expect { result = sign_in(build(:auth_profile, email: "Robin@Example.com")) }.not_to change { record_counts }
      expect(result).to have_attributes(user: nil, failure_reason: :email_conflict)
    end

    it "refuses the same identity at another provider" do
      identity = create(:identity, provider: "example", uid: "42")

      result = sign_in(build(:auth_profile, provider: "another", uid: "42", email: identity.user.email))

      expect(result.failure_reason).to eq(:email_conflict)
    end
  end

  context "with a known identity whose invite is no longer pending" do
    it "signs in without checking the invite again" do
      identity = create(:identity, provider: "example")
      create(:invite, :revoked, email: identity.user.email)

      result = sign_in(build(:auth_profile, provider: "example", uid: identity.uid, email: identity.email))

      expect(result).to be_success
      expect(result.user).to eq(identity.user)
    end
  end

  context "with an unknown identity and a new email" do
    it "refuses an email without an invite and creates nothing" do
      result = nil

      expect { result = sign_in(build(:auth_profile, email: "robin@example.com")) }.not_to change { record_counts }
      expect(result).to have_attributes(user: nil, failure_reason: :not_invited)
    end

    it "refuses an email whose invite was revoked, and leaves the invite alone" do
      invite = create(:invite, :revoked, email: "robin@example.com")

      result = nil

      expect { result = sign_in(build(:auth_profile, email: "robin@example.com")) }.not_to change { record_counts }
      expect(result.failure_reason).to eq(:not_invited)
      expect(invite.reload).to have_attributes(status: "revoked", user: nil)
    end

    it "doesn't match Gmail dot or plus aliases" do
      create(:invite, email: "robin.budgie@gmail.com")

      expect(sign_in(build(:auth_profile, email: "robinbudgie@gmail.com")).failure_reason).to eq(:not_invited)
      expect(sign_in(build(:auth_profile, email: "robin.budgie+budget@gmail.com")).failure_reason).to eq(:not_invited)
    end

    it "creates nothing, and doesn't accept the invite, when creating the user fails" do
      invite = create(:invite, email: "robin@example.com")
      allow_any_instance_of(Identity).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)

      expect { sign_in(build(:auth_profile, email: "robin@example.com")) rescue nil }.not_to change { record_counts }
      expect(invite.reload).to be_pending
    end
  end

  context "with an unknown identity and a new email that has a pending invite" do
    let!(:invite) { create(:invite, email: "robin@example.com") }

    it "accepts the invite for the new user" do
      freeze_time do
        result = sign_in(build(:auth_profile, email: "Robin@Example.com"))

        expect(invite.reload).to have_attributes(status: "accepted", accepted_at: Time.current, user: result.user)
      end
    end

    it "creates the user and the identity" do
      profile = build(:auth_profile,
        provider: "example", uid: "42",
        email: "Robin@Example.com", name: "Robin Budgie", avatar_url: "https://example.com/avatars/robin.png")

      result = nil

      expect { result = sign_in(profile) }.to change(User, :count).by(1).and change(Identity, :count).by(1)
      expect(result).to be_success
      expect(result.user).to have_attributes(
        email: "robin@example.com", name: "Robin Budgie", avatar_url: "https://example.com/avatars/robin.png"
      )
      expect(result.user.identities.sole).to have_attributes(provider: "example", uid: "42", email: "Robin@Example.com")
    end
  end
end
