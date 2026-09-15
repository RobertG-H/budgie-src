# What an identity provider vouches for about the person signing in, in terms that don't depend on the provider.
# Each provider has a mapper in app/models/auth_profile/ that builds one from OmniAuth's auth hash.
AuthProfile = Data.define(:provider, :uid, :email, :email_verified, :name, :avatar_url) do
  def self.from_omniauth(auth)
    const_get(auth.provider.to_s.camelize, false).call(auth)
  end
end
