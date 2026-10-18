require "rails_helper"

RSpec.describe "User guide", type: :request do
  let(:user) { create(:user, :with_budget) }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  it "sends a visitor who isn't signed in to sign in" do
    get guide_path

    expect(response).to redirect_to(sign_in_path)
  end

  it "has every section, in order, each linked from the list at the top" do
    sign_in_as user

    get guide_path

    expect(response).to have_http_status(:ok)
    assert_select "h1", text: "User guide"
    headings = css_select("main section > h2").map { |heading| heading.text.squish }
    expect(headings).to eq(GuidesHelper::GUIDE_SECTIONS.values)

    links = css_select("main nav[aria-label='On this page'] a")
    expect(links.map { |link| link["href"] }).to eq(GuidesHelper::GUIDE_SECTIONS.keys.map { |id| "##{id}" })
    links.each do |link|
      assert_select "main section#{link["href"]}[aria-labelledby]", count: 1
    end
  end

  it "says what a Filing rule did is To review, and how to Mark reviewed, never with the words a person doesn't use for it" do
    sign_in_as user

    get guide_path

    expect(visible_text).to include("To review", "Mark reviewed")
    expect(visible_text).not_to match(/\b(check|confirm|approve|unconfirmed|pending)\b/i)
  end

  it "says what every figure means, in the words the tooltips and the month view use" do
    sign_in_as user

    get guide_path

    HelpHelper::TERMS.each_key do |key|
      expect(visible_text).to include(I18n.t("help.#{key}"))
    end
  end

  it "can be read before the budget is set up" do
    sign_in_as create(:user)

    get guide_path

    expect(response).to have_http_status(:ok)
    assert_select "h1", text: "User guide"
  end
end
