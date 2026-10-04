require "rails_helper"

RSpec.describe "components/_field", type: :view do
  # Puts what the block is given onto a plain input, so the spec can look at it.
  def render_field(record: Budget::Envelope.new, attribute: :name, **options)
    render inline: <<~ERB, locals: { record: record, attribute: attribute, options: options }
      <%= form_with model: record, url: "#" do |form| %>
        <%= render "components/field", form: form, attribute: attribute, **options do |field| %>
          <%= tag.input type: "text", id: form.field_id(attribute), **field %>
        <% end %>
      <% end %>
    ERB
  end

  it "labels the control" do
    render_field

    assert_select "label[for=envelope_name]", text: "Name"
    assert_select "input#envelope_name.input"
  end

  it "takes the label's text from the label local" do
    render_field label: "Envelope name"

    assert_select "label[for=envelope_name]", text: "Envelope name"
  end

  describe "with the label hidden" do
    it "keeps the label for assistive technology but takes it out of sight" do
      render_field label: "Assigned to Groceries in September 2026", hide_label: true

      assert_select "label.sr-only[for=envelope_name]", text: "Assigned to Groceries in September 2026"
      assert_select "label.block", count: 0
      assert_select "input#envelope_name.input"
    end

    it "still ties a hint and an error to the control" do
      render_field hide_label: true, hint: "Helpful", error: "Name can't be blank"

      assert_select "input[aria-describedby='envelope_name_hint envelope_name_error']"
      assert_select "p#envelope_name_error", text: "Name can't be blank"
    end

    it "hides a checkbox's label, and a group of radio buttons' legend, too" do
      render_field control: :checkbox, hide_label: true
      assert_select "input.checkbox + label.sr-only", text: "Name"

      render inline: <<~ERB
        <%= form_with model: Budget::Deposit.new, url: "#" do |form| %>
          <%= render "components/field", form: form, attribute: :month, control: :radios, hide_label: true do |field| %>
            <%= form.radio_button :month, "2026-09-01", **field %>
          <% end %>
        <% end %>
      ERB
      assert_select "fieldset > legend.sr-only", text: "Ready to Assign in"
    end

    it "shows the label as usual when it isn't asked to hide it" do
      render_field hide_label: false

      assert_select "label.block.font-medium[for=envelope_name]", text: "Name"
      assert_select "label.sr-only", count: 0
    end
  end

  it "gives the control a border dark enough to see, and marks nothing invalid" do
    render_field

    assert_select "input[class~='border-base-content/55']"
    assert_select "input[aria-invalid]", count: 0
    assert_select "input[aria-describedby]", count: 0
  end

  it "ties a hint to the control" do
    render_field hint: "Helpful"

    assert_select "p#envelope_name_hint", text: "Helpful"
    assert_select "input[aria-describedby=envelope_name_hint]"
  end

  it "marks the control invalid when its attribute has errors, without repeating the message" do
    record = Budget::Envelope.new.tap { |envelope| envelope.errors.add(:name, "can't be blank") }

    render_field record: record

    assert_select "input.input-error[aria-invalid=true]"
    assert_select "input[class~='border-base-content/55']", count: 0
    assert_select "p", text: /can't be blank/, count: 0
  end

  it "doesn't mark a control invalid for another attribute's errors" do
    record = Budget::Envelope.new.tap { |envelope| envelope.errors.add(:starting_balance, "is invalid") }

    render_field record: record

    assert_select "input[aria-invalid]", count: 0
  end

  it "shows an error under the control and ties it to the control, after the hint" do
    render_field hint: "Helpful", error: "Name can't be blank"

    assert_select "p#envelope_name_error", text: "Name can't be blank"
    assert_select "input.input-error[aria-invalid=true][aria-describedby='envelope_name_hint envelope_name_error']"
  end

  it "works without a record, for a form with only a scope" do
    render inline: <<~ERB
      <%= form_with scope: :sample, url: "#" do |form| %>
        <%= render "components/field", form: form, attribute: :name do |field| %>
          <%= form.text_field :name, **field %>
        <% end %>
      <% end %>
    ERB

    assert_select "label[for=sample_name]", text: "Name"
    assert_select "input#sample_name.input[name='sample[name]']"
  end

  {
    input: "input",
    select: "select",
    textarea: "textarea",
    checkbox: "checkbox"
  }.each do |control, css_class|
    it "gives a #{control} the #{css_class} class, and #{css_class}-error when invalid" do
      render_field control: control
      assert_select "input.#{css_class}"

      render_field control: control, error: "Wrong"
      assert_select "input.#{css_class}-error"
    end
  end

  it "puts a checkbox's label beside it, not above" do
    render_field control: :checkbox

    assert_select "div.flex > input.checkbox + label", text: "Name"
  end

  describe "a group of radio buttons" do
    # The block renders each choice, as a field's block renders its one control.
    def render_radios(record: Budget::Deposit.new, **options)
      render inline: <<~ERB, locals: { record: record, options: options }
        <%= form_with model: record, url: "#" do |form| %>
          <%= render "components/field", form: form, attribute: :month, control: :radios, **options do |field| %>
            <% [ "2026-09-01", "2026-10-01" ].each do |value| %>
              <label><%= form.radio_button :month, value, **field %> <%= value %></label>
            <% end %>
          <% end %>
        <% end %>
      ERB
    end

    it "is a fieldset with a legend, named for the attribute the way the model names it, not a label" do
      render_radios

      assert_select "fieldset > legend", text: "Ready to Assign in"
      assert_select "fieldset input[type=radio]", count: 2
      assert_select "label[for=deposit_month]", count: 0
    end

    it "takes the legend's text from the label local" do
      render_radios label: "Counts toward"

      assert_select "fieldset > legend", text: "Counts toward"
    end

    it "makes up a legend without a record, for a form with only a scope" do
      render inline: <<~ERB
        <%= form_with scope: :sample, url: "#" do |form| %>
          <%= render "components/field", form: form, attribute: :favourite_colour, control: :radios do |field| %>
            <%= form.radio_button :favourite_colour, "blue", **field %>
          <% end %>
        <% end %>
      ERB

      assert_select "fieldset > legend", text: "Favourite colour"
    end

    it "gives each radio button the radio class, and marks nothing invalid" do
      render_radios

      assert_select "input.radio.radio-primary", count: 2
      assert_select "input[aria-invalid]", count: 0
    end

    it "marks every radio button invalid when the attribute has errors" do
      record = Budget::Deposit.new.tap { |deposit| deposit.errors.add(:month, "must be September 2026 or October 2026") }

      render_radios record: record

      assert_select "input.radio.radio-error[aria-invalid=true]", count: 2
      assert_select "input.radio-primary", count: 0
    end

    it "ties a hint to every radio button" do
      render_radios hint: "Choose the month after to save it for next month."

      assert_select "p#deposit_month_hint", text: "Choose the month after to save it for next month."
      assert_select "input[type=radio][aria-describedby=deposit_month_hint]", count: 2
    end
  end
end
