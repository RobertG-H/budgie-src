Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  get "sign_in" => "sessions#new"
  resource :session, only: :destroy

  # OmniAuth handles POST /auth/:provider itself. See config/initializers/omniauth.rb.
  get "auth/:provider/callback" => "sessions#create", as: :auth_callback,
    constraints: { provider: Regexp.union(Rails.configuration.x.auth_providers.keys.map(&:to_s)) }
  get "auth/failure" => "sessions#failure", as: :auth_failure

  # Sent emails, such as invites, land here instead of being delivered.
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "home#index"
end
