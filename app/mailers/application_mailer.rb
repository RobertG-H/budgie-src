class ApplicationMailer < ActionMailer::Base
  # Read when a message is built, so the production image can boot, and precompile its assets, without MAILER_FROM.
  default from: -> {
    ENV.fetch("MAILER_FROM") { Rails.env.production? ? raise(KeyError, "MAILER_FROM isn't set") : "no-reply@localhost" }
  }
  layout "mailer"
end
