# Specs never talk to a real provider. In test mode OmniAuth skips the round trip and hands the
# callback whatever is in OmniAuth.config.mock_auth for that provider.
OmniAuth.config.test_mode = true

module OmniAuthHelpers
  # Shaped like the auth hash omniauth-google-oauth2 builds, which leaves info.email out
  # unless Google has verified the address.
  def google_auth_hash(uid: "109876543210", email: "robin@example.com", email_verified: true, name: "Robin Budgie", image: "https://lh3.googleusercontent.com/a/robin")
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: {
        name: name,
        email: (email if email_verified),
        unverified_email: email,
        email_verified: email_verified,
        image: image
      }.compact
    )
  end

  # Leaves the response as the callback's redirect.
  def sign_in_with_google(**auth)
    OmniAuth.config.mock_auth[:google_oauth2] = google_auth_hash(**auth)
    post "/auth/google_oauth2"
    follow_redirect!
  end
end

RSpec.configure do |config|
  config.include OmniAuthHelpers

  config.after do
    OmniAuth.config.mock_auth.delete(:google_oauth2)
  end
end
