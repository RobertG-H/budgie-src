require "rails_helper"

RSpec.describe "components/_form_actions", type: :view do
  # Rendered inside a real form, since the submit button is the form's own.
  def render_actions(cancel_path: "/months/2026-09", submit: nil)
    render inline: <<~ERB, locals: { cancel_path: cancel_path, submit: submit }
      <%= form_with model: Budget::Spend.new, url: "/spends" do |form| %>
        <%= render "components/form_actions", form: form, cancel_path: cancel_path, submit: submit %>
      <% end %>
    ERB
  end

  it "is the form's submit button, as the main action" do
    render_actions

    assert_select "form input[type=submit].btn.btn-primary[value='Create Spend']"
  end

  it "says what it's told to instead, such as Import" do
    render_actions(submit: "Import")

    assert_select "form input[type=submit].btn.btn-primary[value=Import]"
    assert_select "form input[type=submit]", count: 1
  end

  it "is a Cancel link to where the form was opened from" do
    render_actions(cancel_path: "/months/2026-09/envelopes/3")

    assert_select "form a.btn.btn-ghost[href='/months/2026-09/envelopes/3']", text: "Cancel"
  end

  it "puts the submit button before Cancel, side by side" do
    render_actions

    assert_select "div.flex.items-center" do
      assert_select "input[type=submit] + a", text: "Cancel"
    end
  end
end
