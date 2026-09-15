require "rails_helper"

RSpec.describe Session, type: :model do
  it { is_expected.to belong_to(:user) }

  it "is active from the moment it starts" do
    freeze_time

    expect(create(:session).last_active_at).to eq(Time.current)
  end

  describe "#expired?" do
    before { freeze_time }

    it "is false for a session used within the last 30 days" do
      expect(build(:session, last_active_at: 30.days.ago)).not_to be_expired
    end

    it "is true for a session unused for more than 30 days" do
      expect(build(:session, last_active_at: 30.days.ago - 1.second)).to be_expired
    end
  end

  describe "#record_activity" do
    before { freeze_time }

    it "doesn't write within an hour of the last update" do
      session = create(:session, last_active_at: 59.minutes.ago)

      expect { session.record_activity }.not_to change { session.reload.last_active_at }
    end

    it "updates last_active_at once an hour has passed" do
      session = create(:session, last_active_at: 61.minutes.ago)

      expect { session.record_activity }.to change { session.reload.last_active_at }.to(Time.current)
    end
  end
end
