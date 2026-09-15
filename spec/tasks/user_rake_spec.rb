require "rails_helper"

RSpec.describe "user rake tasks", type: :task do
  describe "user:delete" do
    let!(:user) { create(:user, email: "robin@example.com") }

    before do
      create(:identity, user: user)
      create(:session, user: user)
      create(:invite, :accepted, email: user.email, user: user)
    end

    it "deletes the user, their identities, sessions and invite once the email is typed to confirm" do
      output = nil

      expect { output = run_task("user:delete", stdin: "Robin@Example.com\n", "EMAIL" => "robin@example.com") }
        .to change(User, :count).by(-1).and change(Identity, :count).by(-1)
        .and change(Session, :count).by(-1).and change(Invite, :count).by(-1)
      expect(output).to include("1 identity, 1 session and their invite", "Deleted robin@example.com.")
    end

    it "lets the email be invited again afterwards" do
      run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(Invite.issue!("robin@example.com")).to be_pending
    end

    it "deletes nothing unless the email is typed" do
      expect { expect_task_failure("user:delete", "Not deleted.\n", stdin: "yes\n", "EMAIL" => "robin@example.com") }
        .not_to change(User, :count)
    end

    it "deletes nothing without input to confirm with" do
      expect { expect_task_failure("user:delete", "Not deleted.\n", stdin: "", "EMAIL" => "robin@example.com") }
        .not_to change(User, :count)
    end

    it "fails for an email without a user" do
      expect_task_failure("user:delete", /No user has the email someone@example.com/, "EMAIL" => "Someone@example.com")
    end

    it "fails without EMAIL" do
      expect_task_failure("user:delete", /Usage: bin\/rails user:delete EMAIL=/, "EMAIL" => nil)
    end
  end
end
