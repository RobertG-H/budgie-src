# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # The authorization code a provider's redirect brings back, which is swapped for a token (SplitwiseCallbacksController).
  :code,
  # What Plaid Link gives back, which is swapped for a bank connection's token (PlaidConnectionsController). `:token` covers it too; it's named so it stays covered.
  :public_token
]
