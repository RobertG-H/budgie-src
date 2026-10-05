require "rails_helper"

RSpec.describe "components/_table", type: :view do
  def render_table(caption: "Groceries", body: "<thead><tr><th>Text</th></tr></thead><tbody><tr><td>loblaws</td></tr></tbody>")
    render inline: %(<%= render("components/table", caption: #{caption.inspect}) do %>#{body}<% end %>)
  end

  it "is a table in a wrapper of its own that scrolls sideways, so the page never does, and has the border of a record list" do
    render_table

    assert_select "div.overflow-x-auto.rounded-box.border.border-base-300 > table.table.table-sm"
  end

  it "has a caption that names it and is for assistive technology only" do
    render_table caption: "Groceries"

    assert_select "table > caption.sr-only", text: "Groceries"
  end

  it "holds what it's given, which is the head and the body" do
    render_table

    assert_select "table thead th", text: "Text"
    assert_select "table tbody td", text: "loblaws"
  end

  it "escapes the caption, since it can be an envelope's name" do
    render_table caption: "<b>Bold</b>"

    assert_select "caption b", count: 0
    expect(rendered).to include("&lt;b&gt;")
  end
end
