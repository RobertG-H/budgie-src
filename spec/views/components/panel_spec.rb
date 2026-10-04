require "rails_helper"

RSpec.describe "components/_panel", type: :view do
  it "is a bordered box that holds what it's given, which is a div unless it's given another tag" do
    render inline: %(<%= render("components/panel") do %>Hydro<% end %>)

    assert_select "div.rounded-box.border.border-base-300.p-4", text: "Hydro"
  end

  it "can be a fieldset, for a group of fields with a legend" do
    render inline: %(<%= render("components/panel", tag: :fieldset) do %><legend>Filing rule</legend><% end %>)

    assert_select "fieldset.rounded-box.border.border-base-300.p-4 > legend", text: "Filing rule"
  end

  it "puts the class it's given with its own, and any other attributes on the box" do
    render inline: %(<%= render("components/panel", class: "mt-6 space-y-4", data: { controller: "example" }, id: "box") do %>Inside<% end %>)

    assert_select "div#box.rounded-box.mt-6.space-y-4[data-controller=example]", text: "Inside"
  end

  it "escapes what it's given and hasn't been made safe" do
    render inline: %(<%= render("components/panel") do %><%= "<b>Bold</b>" %><% end %>)

    assert_select "b", count: 0
    expect(rendered).to include("&lt;b&gt;")
  end
end
