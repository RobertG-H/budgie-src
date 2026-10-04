require "rails_helper"

RSpec.describe "components/_delete_button", type: :view do
  def render_button(**locals)
    render partial: "components/delete_button", locals: { path: "/deposits/7", confirm: "Delete the Paycheck deposit?" }.merge(locals)
  end

  it "is a button that deletes the record at the path" do
    render_button

    assert_select "form[action='/deposits/7'][method=post]" do
      assert_select "input[name='_method'][value=delete]"
      assert_select "button", text: "Delete"
    end
  end

  it "asks before it does, through Turbo's confirmation" do
    render_button

    assert_select "form[data-turbo-confirm='Delete the Paycheck deposit?']"
  end

  it "sends along the params it's given, such as the page the record was opened from" do
    render_button params: { from: "deposits", month: "2026-09" }

    assert_select "form input[type=hidden][name=from][value=deposits]"
    assert_select "form input[type=hidden][name=month][value='2026-09']"
  end

  it "sends nothing else by default" do
    render_button

    assert_select "form input[type=hidden]:not([name=_method]):not([name=authenticity_token])", count: 0
  end

  it "is a quiet button, with the error colour for its text" do
    render_button

    assert_select "button.btn.btn-ghost.text-error", text: "Delete"
  end

  it "escapes what it asks" do
    render_button confirm: %(Delete the "<b>Rent</b>" envelope?)

    assert_select "b", count: 0
    assert_select "form[data-turbo-confirm]" do |forms|
      expect(forms.first["data-turbo-confirm"]).to eq(%(Delete the "<b>Rent</b>" envelope?))
    end
  end
end
