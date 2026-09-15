require "rails_helper"

RSpec.describe "Authentication", type: :request do
  let(:user) { create(:user, :with_budget) }

  describe "a protected page" do
    it "redirects a signed-out visitor to the sign-in page" do
      get root_path

      expect(response).to redirect_to(sign_in_path)
    end

    it "is shown to a signed-in user, with a way to sign out" do
      sign_in_as user

      get root_path

      expect(response).to have_http_status(:ok)
      assert_select "nav form[action='#{session_path}'] button", text: "Sign out"
    end
  end

  describe "after signing in" do
    # sign_in_with_google's default email, so its first sign-in may create the user.
    before { create(:invite, email: "robin@example.com") }

    it "returns the visitor to the page they asked for" do
      get root_path(ref: "bookmark")

      sign_in_with_google

      expect(response).to redirect_to(root_url(ref: "bookmark"))
    end

    it "goes to the root page when the visitor didn't ask for one" do
      sign_in_with_google

      expect(response).to redirect_to(root_url)
    end

    it "ignores pages that Turbo only prefetched" do
      get root_path(ref: "bookmark")
      get root_path(ref: "hovered"), headers: { "X-Sec-Purpose" => "prefetch" }

      sign_in_with_google

      expect(response).to redirect_to(root_url(ref: "bookmark"))
    end

    it "ignores form submissions, which a redirect can't repeat" do
      delete session_path

      sign_in_with_google

      expect(response).to redirect_to(root_url)
    end
  end

  describe "session expiry" do
    it "keeps a session used within the last 30 days" do
      sign_in_as user
      travel 30.days - 1.minute

      get root_path

      expect(response).to have_http_status(:ok)
    end

    it "rejects and deletes a session unused for more than 30 days" do
      user_session = sign_in_as user
      travel 30.days + 1.minute

      get root_path

      expect(response).to redirect_to(sign_in_path)
      expect(Session.exists?(user_session.id)).to be(false)
      expect(cookies["session_id"]).to be_blank
    end

    it "counts from the session's last use, not from sign-in" do
      sign_in_as user
      travel 20.days
      get root_path
      travel 20.days

      get root_path

      expect(response).to have_http_status(:ok)
    end
  end

  it "records a session's activity at most once an hour" do
    user_session = sign_in_as user

    travel 30.minutes
    expect { get root_path }.not_to change { user_session.reload.last_active_at }

    travel 31.minutes
    expect { get root_path }.to change { user_session.reload.last_active_at }.to(Time.current)
  end
end
