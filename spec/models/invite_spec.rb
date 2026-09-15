require "rails_helper"

RSpec.describe Invite, type: :model do
  subject { build(:invite) }

  it { is_expected.to belong_to(:user).optional }
  it { is_expected.to validate_presence_of(:email) }
  # Case can't matter: the email is lowercased before it's checked.
  it { is_expected.to validate_uniqueness_of(:email).ignoring_case_sensitivity }

  it "strips and lowercases the email" do
    expect(Invite.new(email: "  Robin@Example.COM\n").email).to eq("robin@example.com")
  end

  it "rejects something that isn't an email address" do
    expect(build(:invite, email: "robin at example")).not_to be_valid
  end

  describe "#status" do
    it "is pending until it's accepted or revoked" do
      expect(build(:invite)).to have_attributes(status: "pending", pending?: true)
    end

    it "is accepted once accepted" do
      expect(build(:invite, :accepted)).to have_attributes(status: "accepted", accepted?: true)
    end

    it "is revoked once revoked" do
      expect(build(:invite, :revoked)).to have_attributes(status: "revoked", revoked?: true)
    end
  end

  describe "status scopes" do
    it "find invites by their derived status" do
      pending = create(:invite)
      accepted = create(:invite, :accepted)
      revoked = create(:invite, :revoked)

      expect(Invite.pending).to contain_exactly(pending)
      expect(Invite.accepted).to contain_exactly(accepted)
      expect(Invite.revoked).to contain_exactly(revoked)
    end
  end

  describe ".issue!" do
    it "invites a new email and sends the invite" do
      invite = nil

      expect { invite = Invite.issue!(" Robin@Example.com ") }
        .to change(Invite, :count).by(1).and change(ActionMailer::Base.deliveries, :count).by(1)
      expect(invite).to be_pending
      expect(invite.email).to eq("robin@example.com")
      expect(ActionMailer::Base.deliveries.last.to).to eq([ "robin@example.com" ])
    end

    it "refuses an email with a pending invite and points to resend" do
      create(:invite, email: "robin@example.com")

      expect { Invite.issue!("robin@example.com") }.to raise_error(Invite::Refused, /pending invite.*invite:resend/)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "refuses an email whose invite was accepted" do
      create(:invite, :accepted, email: "robin@example.com")

      expect { Invite.issue!("robin@example.com") }.to raise_error(Invite::Refused, "robin@example.com is already a user.")
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "invites a revoked email again on the same row, as if newly invited" do
      invite = create(:invite, :revoked, email: "robin@example.com", created_at: 1.week.ago)

      freeze_time do
        expect { Invite.issue!("robin@example.com") }
          .to not_change(Invite, :count).and change(ActionMailer::Base.deliveries, :count).by(1)
        expect(invite.reload).to have_attributes(status: "pending", revoked_at: nil, created_at: Time.current)
      end
    end

    it "raises for an invalid email and sends nothing" do
      expect { Invite.issue!("not an email") }.to raise_error(ActiveRecord::RecordInvalid)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe ".resend!" do
    it "sends a pending invite again without changing it" do
      invite = create(:invite, email: "robin@example.com", created_at: 1.week.ago)

      expect { Invite.resend!("Robin@example.com") }
        .to change(ActionMailer::Base.deliveries, :count).by(1).and not_change { invite.reload.created_at }
    end

    it "refuses an email that hasn't been invited" do
      expect { Invite.resend!("robin@example.com") }.to raise_error(Invite::Refused, /hasn't been invited/)
    end

    it "refuses accepted and revoked invites" do
      create(:invite, :accepted, email: "accepted@example.com")
      create(:invite, :revoked, email: "revoked@example.com")

      expect { Invite.resend!("accepted@example.com") }.to raise_error(Invite::Refused, /is accepted/)
      expect { Invite.resend!("revoked@example.com") }.to raise_error(Invite::Refused, /is revoked/)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe ".revoke!" do
    it "revokes a pending invite and keeps the row" do
      invite = create(:invite, email: "robin@example.com")

      expect { Invite.revoke!("ROBIN@example.com") }.not_to change(Invite, :count)
      expect(invite.reload).to be_revoked
    end

    it "refuses an accepted invite" do
      invite = create(:invite, :accepted, email: "robin@example.com")

      expect { Invite.revoke!("robin@example.com") }.to raise_error(Invite::Refused, /already been accepted/)
      expect(invite.reload).to be_accepted
    end

    it "refuses an invite that's already revoked" do
      create(:invite, :revoked, email: "robin@example.com")

      expect { Invite.revoke!("robin@example.com") }.to raise_error(Invite::Refused, /already revoked/)
    end

    it "refuses an email that hasn't been invited" do
      expect { Invite.revoke!("robin@example.com") }.to raise_error(Invite::Refused, /hasn't been invited/)
    end
  end

  describe "#accept!" do
    it "records when and by whom it was accepted" do
      invite = create(:invite)
      user = create(:user, email: invite.email)

      freeze_time do
        invite.accept!(user)

        expect(invite.reload).to have_attributes(status: "accepted", accepted_at: Time.current, user: user)
      end
    end
  end
end
