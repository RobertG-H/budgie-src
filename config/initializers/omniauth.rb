# OmniAuth runs each enabled provider's side of sign-in: POST /auth/:provider sends the visitor to the
# provider, and the provider's response is checked before the callback reaches SessionsController.
# Providers are enabled in config/auth_providers.yml.
Rails.application.config.middleware.use OmniAuth::Builder do
  providers = Rails.configuration.x.auth_providers

  if providers.key?(:google_oauth2)
    provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"],
      scope: "openid email profile",
      # Budgie doesn't store Google's tokens, so there's no use for a refresh token.
      access_type: "online",
      # Always show Google's account chooser, since signing out of Budgie doesn't sign out of Google.
      prompt: "select_account"
  end
end

OmniAuth.config.logger = Rails.logger

# Redirect every failure to /auth/failure. OmniAuth's default is to raise instead in development.
OmniAuth.config.failure_raise_out_environments = []
