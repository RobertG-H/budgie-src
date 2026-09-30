module DevelopmentRoutes
  # config/routes.rb only draws the development-only routes in development, so controller specs for them
  # draw the same ones into a route set of their own, for the length of the block. Only the request is
  # routed through it: the controller and its views still use the app's own route helpers, such as root_path.
  def with_development_routes
    app_routes = @routes
    self.routes = ActionDispatch::Routing::RouteSet.new.tap do |routes|
      routes.draw do
        scope module: :dev do
          get "styleguide" => "styleguide#show"
          get "dev/sign_in" => "sessions#create", as: :dev_sign_in
        end
      end
    end

    yield
  ensure
    self.routes = app_routes
  end
end

RSpec.configure do |config|
  config.include DevelopmentRoutes, type: :controller

  # Rails loads config/routes.rb the first time a route is needed. These specs stub Rails.env.development?,
  # and routes.rb would then try to mount the development-only letter_opener, so load it first.
  config.before(:suite) { Rails.application.reload_routes_unless_loaded }
end
