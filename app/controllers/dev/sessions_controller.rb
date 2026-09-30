module Dev
  # GET /dev/sign_in signs in as the user db/seeds/development.rb creates, then goes to the root page.
  # It's a GET so a browser tool can simply navigate to it, which is fine because the route only exists in
  # development. Sign-in itself (SignInWithIdentity and invites) isn't touched: this only starts a session.
  class SessionsController < BaseController
    def create
      if (user = User.find_by(email: Dev::USER_EMAIL))
        start_new_session_for user
        redirect_to root_path
      else
        render plain: "There's no development user yet. Run: docker compose run --rm web bin/rails db:seed", status: :not_found
      end
    end
  end
end
