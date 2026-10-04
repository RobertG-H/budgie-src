require "rails_helper"

RSpec.describe "user rake tasks", type: :task do
  describe "user:delete" do
    let!(:user) { create(:user, email: "robin@example.com") }

    before do
      create(:identity, user: user)
      create(:session, user: user)
      create(:invite, :accepted, email: user.email, user: user)
      budget = create(:budget, user: user)
      envelopes = create_list(:budget_envelope, 2, budget: budget)
      create_list(:budget_deposit, 3, budget: budget)
      # Two months of Assigned amounts, three Spends and two Refunds for each envelope, a Reallocation each way between
      # the two and one to Ready to Assign, which an envelope can't be deleted while it has.
      envelopes.each do |envelope|
        [ Date.new(2026, 9, 1), Date.new(2026, 10, 1) ].each { |month| create(:budget_assignment, envelope: envelope, month: month) }
        create_list(:budget_spend, 3, envelope: envelope)
        create_list(:budget_refund, 2, envelope: envelope)
      end
      create(:budget_envelope_reallocation, from_envelope: envelopes.first, to_envelope: envelopes.last)
      create(:budget_envelope_reallocation, from_envelope: envelopes.last, to_envelope: envelopes.first)
      create(:budget_ready_to_assign_reallocation, envelope: envelopes.first)
    end

    it "deletes the user, their identities, sessions, budget, envelopes, Deposits, Assigned amounts, Spends, Refunds, Reallocations (of both kinds) and invite once the email is typed to confirm" do
      output = nil

      expect { output = run_task("user:delete", stdin: "Robin@Example.com\n", "EMAIL" => "robin@example.com") }
        .to change(User, :count).by(-1).and change(Identity, :count).by(-1)
        .and change(Session, :count).by(-1).and change(Invite, :count).by(-1)
        .and change(Budget, :count).by(-1).and change(Budget::Envelope, :count).by(-2)
        .and change(Budget::Deposit, :count).by(-3).and change(Budget::Assignment, :count).by(-4)
        .and change(Budget::Spend, :count).by(-6).and change(Budget::Refund, :count).by(-4)
        .and change(Budget::EnvelopeReallocation, :count).by(-2)
        .and change(Budget::ReadyToAssignReallocation, :count).by(-1)
      expect(output).to include("1 identity, 1 session, their budget with 2 envelopes, 3 deposits, 4 assignments, 6 spends, 4 refunds and 3 reallocations and their invite", "Deleted robin@example.com.")
    end

    it "leaves another user's budget alone" do
      others = create(:budget_assignment)
      others_spend = create(:budget_spend)
      others_refund = create(:budget_refund)
      others_reallocation = create(:budget_envelope_reallocation)
      others_to_ready_to_assign = create(:budget_ready_to_assign_reallocation)

      run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(Budget::Assignment.all).to contain_exactly(others)
      expect(Budget::Spend.all).to contain_exactly(others_spend)
      expect(Budget::Refund.all).to contain_exactly(others_refund)
      expect(Budget::EnvelopeReallocation.all).to contain_exactly(others_reallocation)
      expect(Budget::ReadyToAssignReallocation.all).to contain_exactly(others_to_ready_to_assign)
    end

    it "counts a single envelope, a single deposit, a single assignment, a single spend and a single refund in the singular" do
      kept = user.budget.assignments.first
      Budget::Assignment.where(envelope: user.budget.envelopes).where.not(id: kept.id).delete_all
      Budget::Spend.where(envelope: user.budget.envelopes).where.not(id: kept.envelope.spends.first.id).delete_all
      Budget::Refund.where(envelope: user.budget.envelopes).where.not(id: kept.envelope.refunds.first.id).delete_all
      Budget::EnvelopeReallocation.where(from_envelope: user.budget.envelopes).delete_all
      Budget::ReadyToAssignReallocation.where(envelope: user.budget.envelopes).delete_all
      user.budget.envelopes.where.not(id: kept.envelope_id).destroy_all
      user.budget.deposits.where.not(id: user.budget.deposits.first.id).destroy_all

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("their budget with 1 envelope, 1 deposit, 1 assignment, 1 spend, 1 refund and 0 reallocations and their invite")
    end

    it "counts a single reallocation in the singular" do
      user.budget.envelope_reallocations.last.destroy!
      user.budget.ready_to_assign_reallocations.each(&:destroy!)

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("4 refunds and 1 reallocation and their invite")
    end

    it "counts a budget that has nothing in it" do
      user.budget.assignments.each(&:destroy!)
      user.budget.spends.each(&:destroy!)
      user.budget.refunds.each(&:destroy!)
      user.budget.envelope_reallocations.each(&:destroy!)
      user.budget.ready_to_assign_reallocations.each(&:destroy!)
      user.budget.deposits.destroy_all
      user.budget.envelopes.destroy_all

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("their budget with 0 envelopes, 0 deposits, 0 assignments, 0 spends, 0 refunds and 0 reallocations and their invite")
    end

    it "says when the user has no budget" do
      user.budget.destroy!

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("1 identity, 1 session, no budget and their invite")
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
