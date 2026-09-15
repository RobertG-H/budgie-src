require "rails_helper"

RSpec.describe "invite rake tasks", type: :task do
  describe "invite:create" do
    it "invites the email and sends the invite" do
      expect { expect(run_task("invite:create", "EMAIL" => "robin@example.com")).to eq("Invited robin@example.com.\n") }
        .to change(Invite.pending, :count).by(1).and change(ActionMailer::Base.deliveries, :count).by(1)
    end

    it "fails when the email already has a pending invite" do
      create(:invite, email: "robin@example.com")

      expect_task_failure("invite:create", /invite:resend/, "EMAIL" => "robin@example.com")
    end

    it "fails without EMAIL" do
      expect_task_failure("invite:create", /Usage: bin\/rails invite:create EMAIL=/, "EMAIL" => nil)
    end
  end

  describe "invite:resend" do
    it "resends a pending invite" do
      create(:invite, email: "robin@example.com")

      expect { run_task("invite:resend", "EMAIL" => "robin@example.com") }.to change(ActionMailer::Base.deliveries, :count).by(1)
    end

    it "fails for an email that hasn't been invited" do
      expect_task_failure("invite:resend", /hasn't been invited/, "EMAIL" => "robin@example.com")
    end
  end

  describe "invite:revoke" do
    it "revokes a pending invite" do
      invite = create(:invite, email: "robin@example.com")

      expect(run_task("invite:revoke", "EMAIL" => "robin@example.com")).to eq("Revoked the invite for robin@example.com.\n")
      expect(invite.reload).to be_revoked
    end

    it "fails for an accepted invite" do
      create(:invite, :accepted, email: "robin@example.com")

      expect_task_failure("invite:revoke", /already been accepted/, "EMAIL" => "robin@example.com")
    end
  end

  describe "invite:list" do
    it "lists every invite with its status" do
      create(:invite, email: "pending@example.com")
      create(:invite, :revoked, email: "revoked@example.com")

      lines = run_task("invite:list", "STATUS" => nil).lines

      expect(lines.first).to match(/\AEMAIL\s+STATUS\s+INVITED\s+ACCEPTED\s+REVOKED\n\z/)
      expect(lines.drop(1)).to contain_exactly(/\Apending@example.com\s+pending\s/, /\Arevoked@example.com\s+revoked\s/)
    end

    it "filters by STATUS" do
      create(:invite, email: "pending@example.com")
      create(:invite, :revoked, email: "revoked@example.com")

      output = run_task("invite:list", "STATUS" => "revoked")

      expect(output).to include("revoked@example.com")
      expect(output).not_to include("pending@example.com")
    end

    it "says when there are none" do
      expect(run_task("invite:list", "STATUS" => nil)).to eq("No invites.\n")
    end

    it "fails for an unknown STATUS" do
      expect_task_failure("invite:list", /STATUS must be one of: pending, accepted, revoked/, "STATUS" => "expired")
    end
  end
end
