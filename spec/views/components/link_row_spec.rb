require "rails_helper"

RSpec.describe "components/_link_row", type: :view do
  def render_row(**locals)
    render partial: "components/link_row", locals: { href: "/csv_formats/7/edit", name: "CIBC" }.merge(locals)
  end

  it "is one row of a list, linking to where it's opened" do
    render_row

    assert_select "li a.list-row[href='/csv_formats/7/edit']", count: 1
  end

  it "shows the name" do
    render_row

    assert_select "a.list-row span.font-semibold", text: "CIBC"
  end

  it "shows a detail as a muted second line, and nothing when there's none" do
    render_row detail: "Date in column 1"

    assert_select "span.block[class~='text-base-content/70']", text: "Date in column 1"

    render_row detail: nil

    assert_select "span.block[class~='text-base-content/70']", count: 0
  end

  it "escapes what it's given, since a name is whatever someone typed" do
    render_row name: "<script>alert(1)</script>", detail: "<b>bold</b>"

    assert_select "script", count: 0
    assert_select "b", count: 0
    expect(rendered).to include("&lt;script&gt;")
  end
end
