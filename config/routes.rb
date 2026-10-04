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

  resource :budget, only: [ :new, :create ]

  # The month view is the home page: root is the current month, and any other is /months/YYYY-MM.
  get "months/:month" => "months#show", as: :month
  get "months/:month/deposits" => "deposits#index", as: :month_deposits
  get "months/:month/envelopes/:id" => "envelopes#show", as: :month_envelope
  # What's Assigned to an envelope in a month is one figure, set in place on the month view: its cell there is a
  # Turbo Frame that swaps between the amount (show) and an input for it (edit), and saving sets it (update).
  scope "months/:month/envelopes/:envelope_id", as: :month_envelope do
    resource :assignment, only: [ :show, :edit, :update ]
  end

  resources :deposits, except: [ :index, :show ]
  resources :envelopes, except: [ :index, :show ]

  # Local development only: the styleguide, and a shortcut that signs in as the seeded user. Testing and
  # production both run RAILS_ENV=production, so this is checked against development, never against
  # not-production. The controllers refuse outside development too. See DESIGN.md.
  if Rails.env.development?
    scope module: :dev do
      get "styleguide" => "styleguide#show"
      get "dev/sign_in" => "sessions#create", as: :dev_sign_in
    end
  end

  # Sent emails, such as invites, land here instead of being delivered.
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "months#show"
end
