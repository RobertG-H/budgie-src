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
  resources :envelopes, except: [ :index, :show ] do
    # Putting an envelope away (create) and taking it back (destroy). It's one archive per envelope.
    resource :archive, only: [ :create, :destroy ], controller: "envelope_archives"
  end
  # How each bank lays out its CSV download, built from a sample file. The preview is sent the whole form, sample included, and
  # answers with how the sample reads, so the sample never has to be kept.
  resources :csv_formats, except: :show
  # The real accounts that bank transactions come from, and the CSV files read into them. An Import has no page of its own
  # until it's made, and then it's its summary, which is also where it's undone (destroy).
  resources :accounts do
    resources :imports, only: [ :new, :create ]
  end
  resources :imports, only: [ :show, :destroy ]
  # Filing a bank transaction, as the Deposits, Spends and Refunds it was (create), taking that back (destroy), and ignoring
  # it (and un-ignoring it). Every bank transaction that isn't filed or ignored, across the Accounts, is the Unfiled list.
  resources :bank_transactions, only: [] do
    resource :filing, only: [ :new, :create, :destroy ], controller: "bank_transaction_filings"
    # What "Always file like this" would do with the text as it stands on the filing form, which the form asks for as the text is edited.
    resource :rule_preview, only: :show, path: "filing/rule", controller: "bank_transaction_rule_previews"
    resource :ignore, only: [ :create, :destroy ], controller: "bank_transaction_ignores"
  end
  get "unfiled" => "unfiled_bank_transactions#index", as: :unfiled_bank_transactions
  # "File N as guessed": a page of the Unfiled list's Guesses, reviewed (new) and then filed as they were reviewed (create), in one go.
  resource :guessed_filing, only: [ :new, :create ], path: "unfiled/guessed", controller: "guessed_filings"
  # Standing instructions that file or ignore the bank transactions that come in, the same way each time: all of them in one place, where
  # they're made from scratch, edited and deleted. The sweep is what a rule would do to the unfiled bank transactions that are already
  # there, which the forms ask for as they're edited. Editing or deleting a rule never changes what it already filed.
  resources :filing_rules, except: :show
  resource :filing_rule_sweep, only: :show, path: "filing_rules/sweep", controller: "filing_rule_sweeps"
  post "csv_formats/preview" => "csv_format_previews#create", as: :csv_format_preview
  resources :spends, except: [ :index, :show ]
  resources :refunds, except: [ :index, :show ]
  # One Reallocate form makes either kind of Reallocation, and its To decides which. Editing and deleting are per kind,
  # since ids repeat across the two tables. The Ready to Assign path has hyphens, since the UI never spells it with underscores.
  resources :reallocations, only: [ :new, :create ]
  resources :envelope_reallocations, path: "reallocations/to-envelope", only: [ :edit, :update, :destroy ]
  resources :ready_to_assign_reallocations, path: "reallocations/to-ready-to-assign", only: [ :edit, :update, :destroy ]

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
