require "rails_helper"

# /styleguide and /dev/sign_in are for local development only. Testing and production both run
# RAILS_ENV=production, so what keeps them off those hosts is that config/routes.rb only draws them in
# development. The controllers refuse to act outside it as well: see spec/controllers/dev.
RSpec.describe "Development-only routes", type: :request do
  {
    "/styleguide" => :styleguide_path,
    "/dev/sign_in" => :dev_sign_in_path
  }.each do |path, route_helper|
    describe path do
      it "isn't routable outside development" do
        expect { Rails.application.routes.recognize_path(path) }.to raise_error(ActionController::RoutingError)
        expect(Rails.application.routes.url_helpers).not_to respond_to(route_helper)
      end

      it "is not found, for a signed-in user too" do
        get path
        expect(response).to have_http_status(:not_found)

        sign_in_as create(:user, :with_budget)
        get path
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it "starts no session, even for the seeded development user" do
    create(:user, email: Dev::USER_EMAIL)

    expect { get "/dev/sign_in" }.not_to change(Session, :count)
  end
end
