require "rails_helper"

RSpec.describe Identity, type: :model do
  # The uniqueness matcher needs letters in the uid to check that case matters.
  subject { build(:identity, uid: "uid-abc") }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:provider) }
  it { is_expected.to validate_presence_of(:uid) }
  it { is_expected.to validate_presence_of(:email) }
  it { is_expected.to validate_uniqueness_of(:uid).scoped_to(:provider) }

  it "allows identities that share an email" do
    existing = create(:identity)

    expect(build(:identity, email: existing.email)).to be_valid
  end
end
