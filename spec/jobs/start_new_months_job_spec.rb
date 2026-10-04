require "rails_helper"
# What Solid Queue reads a recurring task's schedule with.
require "fugit"

RSpec.describe StartNewMonthsJob, type: :job do
  let(:september) { Date.new(2026, 9, 1) }
  let(:october) { Date.new(2026, 10, 1) }

  # A budget that began in September, with $400 assigned to Groceries in it.
  def budget_with_groceries
    budget = travel_to(Time.zone.local(2026, 9, 5)) { create(:budget) }
    create(:budget_assignment, envelope: create(:budget_envelope, budget: budget), month: september, amount: 400)
    budget
  end

  # Everything assigned in October, as the month view totals it.
  def assigned_in_october(budget)
    Budget::Month.new(budget, october).ready_to_assign.assigned
  end

  # Eastern Time is four hours behind UTC until early November, so midnight at the start of October 1 is 04:00 UTC.
  it "starts a budget's new month just after midnight Eastern on the 1st" do
    budget = budget_with_groceries

    travel_to Time.utc(2026, 10, 1, 4, 1)
    described_class.perform_now

    expect(assigned_in_october(budget)).to eq(400)
  end

  it "doesn't start it just before midnight Eastern, though it's already the 1st in UTC" do
    budget = budget_with_groceries

    travel_to Time.utc(2026, 10, 1, 3, 59)
    described_class.perform_now

    expect(assigned_in_october(budget)).to eq(0)
  end

  it "starts the new month of every budget that's behind" do
    budgets = [ budget_with_groceries, budget_with_groceries ]

    travel_to Time.utc(2026, 10, 1, 4, 1)
    described_class.perform_now

    expect(budgets.map { |budget| assigned_in_october(budget) }).to eq([ 400, 400 ])
  end

  describe "its entry in config/recurring.yml" do
    let(:entry) { Rails.application.config_for(:recurring, env: "production").fetch(:start_new_months) }

    it "runs this job, in production" do
      expect(entry[:class].constantize).to eq(described_class)
    end

    it "runs every hour, so a month begins within an hour of midnight Eastern" do
      schedule = Fugit.parse(entry[:schedule])
      first = schedule.next_time(Time.utc(2026, 10, 1, 3, 0, 1))
      second = schedule.next_time(first + 1)

      expect(second - first).to eq(1.hour)
    end
  end
end
