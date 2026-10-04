require "rails_helper"

# db:prepare seeds a new database in every environment, including the testing and production hosts, so the
# development user must only ever be created in development.
RSpec.describe "db/seeds.rb" do
  def run_seeds
    load Rails.root.join("db/seeds.rb")
  end

  it "creates no development user outside development" do
    expect { run_seeds }.not_to change(User, :count)

    expect(User.find_by(email: Dev::USER_EMAIL)).to be_nil
  end

  it "creates no Deposits outside development" do
    expect { run_seeds }.not_to change(Budget::Deposit, :count)
  end

  context "in development" do
    before { allow(Rails.env).to receive(:development?).and_return(true) }

    it "creates the user /dev/sign_in signs in as, with a budget and envelopes, and no way in through Google" do
      run_seeds

      user = User.find_by!(email: Dev::USER_EMAIL)
      expect(user.identities).to be_empty
      expect(user.budget.currency).to eq("USD")
      expect(user.budget.envelopes.pluck(:starting_balance)).to include(be_negative, be_zero, be_positive)
    end

    it "adds a $3,000 Paycheck on the 1st of last month and of this month, and none the month before" do
      # Still October 15 in Eastern time.
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      deposits = User.find_by!(email: Dev::USER_EMAIL).budget.deposits.order(:date)
      expect(deposits.pluck(:description, :date, :month, :amount)).to eq([
        [ "Paycheck", Date.new(2026, 9, 1), Date.new(2026, 9, 1), 3000 ],
        [ "Paycheck", Date.new(2026, 10, 1), Date.new(2026, 10, 1), 3000 ]
      ])
    end

    it "has Ready to Assign carried over into this month, and nothing before last month" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      expect(Budget::Month.new(budget, Date.new(2026, 8, 1)).ready_to_assign).to have_attributes(carried_over: 0, deposited: 0)
      expect(Budget::Month.new(budget, Date.new(2026, 10, 1)).ready_to_assign).to have_attributes(carried_over: 3000, deposited: 3000, amount: 6000)
    end

    it "changes nothing when it's run again" do
      run_seeds

      expect { run_seeds }.not_to change { [ User.count, Budget.count, Budget::Envelope.count, Budget::Deposit.count ] }
    end

    it "leaves a Deposit the developer has changed" do
      run_seeds
      paycheck = Budget::Deposit.order(:date).last
      paycheck.update!(amount: 1)

      run_seeds

      expect(paycheck.reload.amount).to eq(1)
    end

    it "leaves a starting balance the developer has changed" do
      run_seeds
      envelope = Budget::Envelope.find_by!(name: "Groceries")
      envelope.update!(starting_balance: 1)

      run_seeds

      expect(envelope.reload.starting_balance).to eq(1)
    end
  end
end
