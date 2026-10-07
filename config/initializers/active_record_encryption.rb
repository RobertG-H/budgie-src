# The keys Active Record encrypts a bank connection's token with. They come from environment variables, because credentials can't be edited from
# this checkout: generate them once with `bin/rails db:encryption:init` and put its primary key and its key derivation salt in the variables of their names
# below, in `.env` and in each destination's secrets (docs/deployment.md). Nothing here is encrypted deterministically, so the third key it prints isn't
# needed. A different key can't read what another wrote, so a lost one means every connection has to be reconnected.
#
# Development and test fall back to fixed throwaway keys so that neither needs setting up: nothing in them is a secret worth keeping. Testing and
# production have no fallback, so a host without the keys has no way to connect (Splitwise.configured? says so) rather than keeping tokens under a key
# that's in the repo.
encryption = Rails.application.config.active_record.encryption

fallbacks = if Rails.env.local?
  { primary_key: "budgie-development-primary-key-not-a-secret", key_derivation_salt: "budgie-development-key-derivation-salt-not-a-secret" }
else
  {}
end

{
  primary_key: "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
  key_derivation_salt: "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
}.each do |option, variable|
  encryption[option] = ENV[variable].presence || fallbacks[option]
end
