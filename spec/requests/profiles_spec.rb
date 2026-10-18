require "rails_helper"

RSpec.describe "Profile", type: :request do
  let(:user) { create(:user, name: "Robin Budgie", email: "robin@example.com", created_at: Time.zone.local(2026, 9, 3, 12)) }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  it "sends a visitor who isn't signed in to sign in" do
    get profile_path

    expect(response).to redirect_to(sign_in_path)
  end

  it "says who the person is signed in as, how they sign in, their budget's currency and when they joined" do
    create(:budget, user: user, currency: "CAD")
    create(:identity, user: user, provider: "google_oauth2", email: "robin@example.com")
    sign_in_as user

    get profile_path

    expect(response).to have_http_status(:ok)
    assert_select "h1", text: "Profile"
    expect(visible_text).to include("Name Robin Budgie", "Email robin@example.com", "Signs in with Google, as robin@example.com",
      "Budget currency Canadian dollar (CAD)", "Joined Sep 3, 2026")
  end

  it "only ever shows the signed-in person's own" do
    create(:budget, user: user)
    someone_else = create(:user, name: "Sam Other", email: "sam@example.com")
    create(:identity, user: someone_else, email: "sam@example.com")
    sign_in_as user

    get profile_path

    expect(visible_text).not_to include("Sam Other", "sam@example.com")
  end

  it "leaves out how they sign in when there's no way, as for the seeded development user" do
    create(:budget, user: user)
    sign_in_as user

    get profile_path

    expect(visible_text).not_to include("Signs in with")
    expect(visible_text).to include("Email robin@example.com", "Joined Sep 3, 2026")
  end

  it "says when there's no name" do
    user.update!(name: nil)
    create(:budget, user: user)
    sign_in_as user

    get profile_path

    expect(visible_text).to include("Name Not given")
  end

  it "is there before the budget is set up, and says so, with the way to set it up" do
    sign_in_as user

    get profile_path

    expect(response).to have_http_status(:ok)
    expect(visible_text).to include("Budget currency Not chosen yet. Set up your budget")
    assert_select "main a[href='#{new_budget_path}']", text: "Set up your budget"
  end
end
