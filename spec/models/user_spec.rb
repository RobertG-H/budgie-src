require "rails_helper"

RSpec.describe User, type: :model do
  subject { build(:user) }

  it { is_expected.to have_many(:identities).dependent(:destroy) }
  it { is_expected.to have_many(:sessions).dependent(:destroy) }
  it { is_expected.to validate_presence_of(:email) }
  # Case can't matter: the email is lowercased before it's checked.
  it { is_expected.to validate_uniqueness_of(:email).ignoring_case_sensitivity }

  it "strips and lowercases the email" do
    expect(User.new(email: "  Robin@Example.COM\n").email).to eq("robin@example.com")
  end

  it "finds users by an unnormalized email" do
    user = create(:user, email: "robin@example.com")

    expect(User.find_by(email: " ROBIN@example.com")).to eq(user)
  end
end
