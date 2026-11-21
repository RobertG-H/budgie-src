require "rails_helper"

RSpec.describe User, type: :model do
  subject { build(:user) }

  it { is_expected.to have_many(:identities).dependent(:destroy) }
  it { is_expected.to have_many(:sessions).dependent(:destroy) }
  it { is_expected.to have_one(:invite).dependent(:destroy) }
  it { is_expected.to have_one(:budget).dependent(:destroy) }
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

  describe "features" do
    let(:user) { create(:user) }

    it "has none to start with" do
      expect(user.features).to eq([])
      expect(user.feature?(:plaid)).to be(false)
    end

    it "turns one on and off, by a symbol or a string, and keeps it once saved" do
      user.enable_feature!(:plaid)

      expect(user.reload.feature?(:plaid)).to be(true)
      expect(user.feature?("plaid")).to be(true)

      user.disable_feature!("plaid")

      expect(user.reload.feature?(:plaid)).to be(false)
    end

    it "turns one on once, however many times it's asked, and off when it's already off" do
      user.enable_feature!(:plaid)
      user.enable_feature!(:plaid)

      expect(user.reload.features).to eq([ "plaid" ])

      user.disable_feature!(:plaid)
      user.disable_feature!(:plaid)

      expect(user.reload.features).to eq([])
    end

    it "raises on a name it doesn't know, so a typo in the console fails loudly" do
      expect { user.enable_feature!(:plad) }.to raise_error(ArgumentError, /plad/)
      expect { user.disable_feature!(:plad) }.to raise_error(ArgumentError, /plad/)
      expect { user.feature?(:plad) }.to raise_error(ArgumentError, /plad/)
    end

    it "refuses an unknown name in the model and in the database" do
      user.features = [ "plad" ]

      expect(user).not_to be_valid
      expect(user.errors[:features]).to be_present
      expect { user.update_columns(features: [ "plad" ]) }.to raise_error(ActiveRecord::StatementInvalid, /users_features_known/)
    end

    it "is turned on by the factory's :plaid trait" do
      expect(create(:user, :plaid).feature?(:plaid)).to be(true)
    end
  end
end
