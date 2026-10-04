require "rails_helper"

RSpec.describe "budget rake tasks", type: :task do
  describe "budget:start_months" do
    let(:october) { Date.new(2026, 10, 1) }

    # A budget that began in September, with $400 assigned to an envelope in it.
    def budget_with_assigned
      budget = travel_to(Time.zone.local(2026, 9, 5)) { create(:budget) }
      create(:budget_assignment, envelope: create(:budget_envelope, budget: budget), month: Date.new(2026, 9, 1), amount: 400)
      budget
    end

    def assigned_in_october(budget)
      Budget::Month.new(budget, october).ready_to_assign.assigned
    end

    it "starts the new month of every budget that's behind, and says how many" do
      budgets = [ budget_with_assigned, budget_with_assigned ]

      travel_to Time.zone.local(2026, 10, 1, 0, 30)
      output = run_task("budget:start_months")

      expect(budgets.map { |budget| assigned_in_october(budget) }).to eq([ 400, 400 ])
      expect(output).to eq("Started the new months of 2 budgets.\n")
    end

    it "counts a single budget in the singular" do
      budget_with_assigned

      travel_to Time.zone.local(2026, 10, 1, 0, 30)

      expect(run_task("budget:start_months")).to eq("Started the new months of 1 budget.\n")
    end

    it "says so when no budget has a month to start" do
      budget = budget_with_assigned

      travel_to Time.zone.local(2026, 9, 20)
      output = run_task("budget:start_months")

      expect(assigned_in_october(budget)).to eq(0)
      expect(output).to eq("No budget has a month to start.\n")
    end
  end

  describe "budget:currency" do
    let!(:user) { create(:user, email: "robin@example.com") }
    let!(:budget) { create(:budget, user: user, currency: "CAD") }

    it "changes the currency once the email is typed to confirm, warning that amounts aren't converted" do
      output = run_task("budget:currency", stdin: "Robin@Example.com\n", "EMAIL" => "robin@example.com", "CURRENCY" => "usd")

      expect(budget.reload.currency).to eq("USD")
      expect(output).to include("from CAD to USD", "Amounts aren't converted", "Changed robin@example.com's budget to USD.")
    end

    it "changes nothing unless the email is typed" do
      expect_task_failure("budget:currency", "Not changed.\n", stdin: "yes\n", "EMAIL" => "robin@example.com", "CURRENCY" => "USD")

      expect(budget.reload.currency).to eq("CAD")
    end

    it "does nothing when the budget is already in that currency" do
      output = run_task("budget:currency", "EMAIL" => "robin@example.com", "CURRENCY" => "CAD")

      expect(output).to eq("robin@example.com's budget is already in CAD.\n")
    end

    it "fails for an unsupported currency" do
      expect_task_failure("budget:currency", /JPY isn't supported. Choose one of: CAD, USD/, "EMAIL" => "robin@example.com", "CURRENCY" => "JPY")

      expect(budget.reload.currency).to eq("CAD")
    end

    it "fails for an email without a user" do
      expect_task_failure("budget:currency", /No user has the email someone@example.com/, "EMAIL" => "Someone@example.com", "CURRENCY" => "USD")
    end

    it "fails for a user without a budget" do
      create(:user, email: "sam@example.com")

      expect_task_failure("budget:currency", /sam@example.com hasn't set up a budget/, "EMAIL" => "sam@example.com", "CURRENCY" => "USD")
    end

    it "fails without EMAIL or CURRENCY" do
      expect_task_failure("budget:currency", /Usage: bin\/rails budget:currency EMAIL=.* CURRENCY=/, "EMAIL" => nil, "CURRENCY" => "USD")
      expect_task_failure("budget:currency", /Usage:/, "EMAIL" => "robin@example.com", "CURRENCY" => nil)
    end
  end
end
