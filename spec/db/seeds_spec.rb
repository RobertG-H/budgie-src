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

  context "in development" do
    before { allow(Rails.env).to receive(:development?).and_return(true) }

    it "creates the user /dev/sign_in signs in as, with a budget and envelopes, and no way in through Google" do
      run_seeds

      user = User.find_by!(email: Dev::USER_EMAIL)
      expect(user.identities).to be_empty
      expect(user.budget.currency).to eq("USD")
      expect(user.budget.envelopes.pluck(:starting_balance)).to include(be_negative, be_zero, be_positive)
    end

    it "changes nothing when it's run again" do
      run_seeds

      expect { run_seeds }.not_to change { [ User.count, Budget.count, Budget::Envelope.count ] }
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
