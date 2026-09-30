module Dev
  # The controllers that only exist for local development, so a developer or Claude can see the app without a
  # Google account. config/routes.rb draws their routes in development alone, and refusing to act anywhere
  # else is the second lock, in case a route is ever drawn by mistake. Testing and production both run
  # RAILS_ENV=production, so this checks for development, never for not-production.
  class BaseController < ApplicationController
    allow_unauthenticated_access
    allow_missing_budget

    # Ahead of everything else, so nothing runs outside development.
    prepend_before_action :require_development

    private
      def require_development
        head :not_found unless Rails.env.development?
      end
  end
end
