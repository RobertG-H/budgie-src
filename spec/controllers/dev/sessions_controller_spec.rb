require "rails_helper"

# The routes for this controller only exist in development, so these draw their own. The request spec in
# spec/requests/development_only_spec.rb covers the routes; this covers the controller's own guard.
RSpec.describe Dev::SessionsController, type: :controller do
  describe "GET /dev/sign_in" do
    context "in development" do
      before { allow(Rails.env).to receive(:development?).and_return(true) }

      it "starts a session for the seeded user and goes to the root page" do
        user = create(:user, email: Dev::USER_EMAIL)

        with_development_routes { get :create }

        expect(response).to redirect_to("/")
        expect(user.sessions.count).to eq(1)
        expect(response.cookies["session_id"]).to be_present
      end

      it "says how to create the user when there isn't one" do
        expect { with_development_routes { get :create } }.not_to change(Session, :count)

        expect(response).to have_http_status(:not_found)
        expect(response.body).to include("bin/rails db:seed")
      end
    end

    context "outside development" do
      it "is not found and starts no session, even when the seeded user exists" do
        user = create(:user, email: Dev::USER_EMAIL)

        with_development_routes { get :create }

        expect(response).to have_http_status(:not_found)
        expect(user.sessions).to be_empty
        expect(response.cookies["session_id"]).to be_blank
      end
    end
  end
end
