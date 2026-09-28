require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Cloudflare terminates TLS, and requests reach the app over plain HTTP through the tunnel and kamal-proxy.
  config.assume_ssl = true

  # Mark cookies secure. Every request counts as HTTPS here, so redirecting http:// is left to
  # Cloudflare's Always Use HTTPS.
  config.force_ssl = true

  # HSTS stays off, here and at Cloudflare, because browsers keep its max-age and it can't be taken back
  # (see docs/cloudflare.md). hsts: false still sends the header, with max-age=0, which tells browsers to forget it.
  # Skip the http-to-https redirect for the health check.
  config.ssl_options = { hsts: false, redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Invites are sent with deliver_now, so the operator should see delivery failures.
  config.action_mailer.raise_delivery_errors = true

  # Links in emails point at this destination's hostname, which Kamal sets. Fetched so that a destination
  # without it fails at boot rather than in someone's inbox.
  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST"), protocol: "https" }

  # Generic SMTP, currently Zedmail's relay, so switching providers only changes these environment variables.
  # Zedmail's SMTP password is its API key. The sender address comes from MAILER_FROM; see ApplicationMailer.
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: ENV["SMTP_ADDRESS"],
    port: ENV.fetch("SMTP_PORT", 587).to_i,
    user_name: ENV["SMTP_USERNAME"],
    password: ENV["SMTP_PASSWORD"],
    authentication: :plain,
    # Refuse to send, rather than fall back to plain text, if the server doesn't offer STARTTLS.
    enable_starttls: true,
    # Invites are sent with deliver_now, so don't leave the operator waiting on an unresponsive server.
    open_timeout: 5,
    read_timeout: 10
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks. Both hosts accept both names,
  # which is harmless because Cloudflare routes each hostname to its own host.
  config.hosts = [ "budgiebuddie.com", "testing.budgiebuddie.com" ]

  # Skip it for the health check, because kamal-proxy's doesn't send a public hostname.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
