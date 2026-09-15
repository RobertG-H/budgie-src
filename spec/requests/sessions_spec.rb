require "rails_helper"

RSpec.describe "Sessions", type: :request do
  def record_counts
    [ User.count, Identity.count, Session.count ]
  end

  describe "GET /sign_in" do
    it "offers nothing but a button for each enabled provider" do
      get sign_in_path

      expect(response).to have_http_status(:ok)
      assert_select "main form", count: 1
      assert_select "main form[action='/auth/google_oauth2'][method=post][data-turbo=false] button", text: "Sign in with Google"
      assert_select "input[type=password]", count: 0
    end

    it "sends a signed-in user to the root page" do
      sign_in_as create(:user)

      get sign_in_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /auth/google_oauth2" do
    around do |example|
      forgery_protection = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = forgery_protection
    end

    it "continues to the provider with the sign-in page's CSRF token" do
      get sign_in_path
      token = css_select("form[action='/auth/google_oauth2'] input[name=authenticity_token]").first["value"]

      post "/auth/google_oauth2", params: { authenticity_token: token }

      expect(response).to redirect_to("http://www.example.com/auth/google_oauth2/callback")
    end

    it "fails without a valid CSRF token" do
      post "/auth/google_oauth2"

      expect(response.location).to start_with("/auth/failure")
    end
  end

  describe "GET /auth/google_oauth2/callback" do
    it "creates the user and identity on first sign-in, and starts a session" do
      expect { sign_in_with_google(uid: "109876543210", email: "Robin@Example.com", name: "Robin Budgie") }
        .to change(User, :count).by(1).and change(Identity, :count).by(1).and change(Session, :count).by(1)

      user = User.sole
      expect(user).to have_attributes(email: "robin@example.com", name: "Robin Budgie")
      expect(user.identities.sole).to have_attributes(provider: "google_oauth2", uid: "109876543210")
      expect(cookies["session_id"]).to be_present
      expect(response).to redirect_to(root_url)
    end

    it "signs a returning user in without creating another" do
      identity = create(:identity, provider: "google_oauth2", uid: "109876543210")

      expect { sign_in_with_google(uid: "109876543210", email: identity.email) }.not_to change(User, :count)
      expect(identity.user.sessions.count).to eq(1)
      expect(response).to redirect_to(root_url)
    end

    it "refuses an unverified email and creates nothing" do
      expect { sign_in_with_google(email_verified: false) }.not_to change { record_counts }
      expect(response).to redirect_to(sign_in_path)
      expect(flash[:alert]).to eq("We couldn't sign you in.")
    end

    it "refuses a new identity whose email already belongs to a user, and creates nothing" do
      create(:user, email: "robin@example.com")

      expect { sign_in_with_google(email: "robin@example.com") }.not_to change { record_counts }
      expect(response).to redirect_to(sign_in_path)
      expect(flash[:alert]).to eq("We couldn't sign you in.")
    end

    it "logs why sign-in was refused without showing it" do
      allow(Rails.logger).to receive(:info).and_call_original

      sign_in_with_google(email_verified: false)

      expect(Rails.logger).to have_received(:info).with(%(Sign-in refused: "unverified_email" from "google_oauth2"))
      expect(flash[:alert]).not_to include("unverified")
    end

    it "doesn't exist for providers that aren't enabled" do
      get "/auth/github/callback"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /auth/failure" do
    it "returns to the sign-in page when the provider's side fails" do
      OmniAuth.config.mock_auth[:google_oauth2] = :access_denied

      post "/auth/google_oauth2"
      follow_redirect!

      expect(response).to redirect_to(auth_failure_path(message: "access_denied", strategy: "google_oauth2"))

      expect { follow_redirect! }.not_to change { record_counts }
      expect(response).to redirect_to(sign_in_path)
      expect(flash[:alert]).to eq("We couldn't sign you in.")
    end
  end

  describe "DELETE /session" do
    it "destroys the session, clears the cookie and returns to the sign-in page" do
      user_session = sign_in_as create(:user)

      delete session_path

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(sign_in_path)
      expect(Session.exists?(user_session.id)).to be(false)
      expect(cookies["session_id"]).to be_blank

      follow_redirect!

      assert_select "[role=status]", text: "You've been signed out."
    end

    it "leaves the visitor signed out" do
      sign_in_as create(:user)
      delete session_path

      get root_path

      expect(response).to redirect_to(sign_in_path)
    end
  end
end
