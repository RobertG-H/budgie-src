require "rails_helper"

RSpec.describe AuthProfile::GoogleOauth2, type: :model do
  it "maps a Google account with a verified email" do
    auth = google_auth_hash(
      uid: "109876543210",
      email: "Robin@Example.com",
      name: "Robin Budgie",
      image: "https://lh3.googleusercontent.com/a/robin"
    )

    expect(described_class.call(auth)).to eq(
      AuthProfile.new(
        provider: "google_oauth2",
        uid: "109876543210",
        email: "Robin@Example.com",
        email_verified: true,
        name: "Robin Budgie",
        avatar_url: "https://lh3.googleusercontent.com/a/robin"
      )
    )
  end

  it "keeps an unverified email but marks it unverified" do
    profile = described_class.call(google_auth_hash(email: "robin@example.com", email_verified: false))

    expect(profile).to have_attributes(email: "robin@example.com", email_verified: false)
  end

  it "treats a missing email_verified claim as unverified" do
    profile = described_class.call(google_auth_hash(email_verified: nil))

    expect(profile.email_verified).to be(false)
  end

  it "only accepts a true email_verified claim, not a truthy one" do
    auth = google_auth_hash
    auth.info.email_verified = "false"

    expect(described_class.call(auth).email_verified).to be(false)
  end
end
