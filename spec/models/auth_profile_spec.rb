require "rails_helper"

RSpec.describe AuthProfile, type: :model do
  describe ".from_omniauth" do
    it "uses the mapper for the auth hash's provider" do
      auth = google_auth_hash

      expect(AuthProfile.from_omniauth(auth)).to eq(AuthProfile::GoogleOauth2.call(auth))
    end

    it "raises for a provider that has no mapper" do
      auth = OmniAuth::AuthHash.new(provider: "unmapped", uid: "1")

      expect { AuthProfile.from_omniauth(auth) }.to raise_error(NameError)
    end
  end
end
