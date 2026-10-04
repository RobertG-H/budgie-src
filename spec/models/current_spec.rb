require "rails_helper"

RSpec.describe Current, type: :model do
  after { Current.reset }

  describe ".budget" do
    it "is the signed-in user's budget" do
      budget = create(:budget)
      Current.session = create(:session, user: budget.user)

      expect(Current.budget).to eq(budget)
    end

    it "is nothing for a user who hasn't set up a budget" do
      Current.session = create(:session)

      expect(Current.budget).to be_nil
    end

    it "is nothing when no one is signed in" do
      expect(Current.budget).to be_nil
    end
  end
end
