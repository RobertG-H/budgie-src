require "rails_helper"

RSpec.describe "budget rake tasks", type: :task do
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
