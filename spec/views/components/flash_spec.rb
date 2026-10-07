require "rails_helper"

RSpec.describe "components/_flash", type: :view do
  def render_flash(type, message = "Something happened.")
    render partial: "components/flash", locals: { type: type, message: message }
  end

  {
    "notice" => { role: "status", variant: "alert-success" },
    "alert" => { role: "alert", variant: "alert-error" },
    "info" => { role: "status", variant: "alert-info" },
    "warning" => { role: "alert", variant: "alert-warning" }
  }.each do |type, expected|
    it "shows a #{type} as #{expected[:variant]}, announced as #{expected[:role]}" do
      render_flash type

      assert_select "[role=#{expected[:role]}].alert.#{expected[:variant]}", text: "Something happened."
    end
  end

  it "accepts the type as a symbol" do
    render_flash :notice

    assert_select "[role=status].alert-success"
  end

  it "shows a type it doesn't know as info" do
    render_flash "other"

    assert_select "[role=status].alert-info"
  end

  it "escapes the message" do
    render_flash "notice", "<b>bold</b>"

    assert_select "b", count: 0
  end

  it "ends with a link to where the person can go on when it's given one" do
    render partial: "components/flash", locals: { type: "notice", message: "Synced.", link: "/bank_transactions?filter[state]=to_review" }

    assert_select "[role=status] a.link[href='/bank_transactions?filter[state]=to_review']", text: "Review them"
  end

  it "has no link without one" do
    render_flash "notice"

    assert_select "a", count: 0
  end
end
