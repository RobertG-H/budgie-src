# Builds an AuthProfile from the auth hash that omniauth-google-oauth2 produces.
module AuthProfile::GoogleOauth2
  def self.call(auth)
    AuthProfile.new(
      provider: auth.provider,
      uid: auth.uid,
      # The strategy leaves info.email blank unless Google has verified the address.
      email: auth.info.email || auth.info.unverified_email,
      email_verified: auth.info.email_verified == true,
      name: auth.info.name,
      avatar_url: auth.info.image
    )
  end
end
