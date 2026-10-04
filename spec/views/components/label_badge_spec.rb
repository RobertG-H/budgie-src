require "rails_helper"

RSpec.describe "components/_label_badge", type: :view do
  it "is a short neutral word, which says what something is and never by colour alone" do
    render partial: "components/label_badge", locals: { text: "Unfiled" }

    assert_select "span.badge.badge-ghost.badge-sm", text: "Unfiled"
  end

  it "escapes what it's given" do
    render partial: "components/label_badge", locals: { text: "<b>Bold</b>" }

    assert_select "b", count: 0
    expect(rendered).to include("&lt;b&gt;")
  end
end
