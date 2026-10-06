require "rails_helper"

# A term explained in one sentence from `help:` in config/locales/en.yml: a tooltip for a mouse or a keyboard, and never the only place the
# explanation is, since a phone can't hover.
RSpec.describe "components/_term", type: :view do
  it "is the term as a focusable element, with the sentence in a real element it's described by" do
    render partial: "components/term", locals: { key: :carried_over }

    assert_select "span.tooltip" do
      assert_select "span[tabindex='0'][aria-describedby='help-carried-over']", text: "Carried over"
      assert_select "span.tooltip-content#help-carried-over[role=tooltip]", text: I18n.t("help.carried_over")
    end
  end

  it "reads the term's own words, such as Ready to Assign, and never spells its key in the markup" do
    render partial: "components/term", locals: { key: :ready_to_assign }

    assert_select "[aria-describedby='help-ready-to-assign']", text: "Ready to Assign"
    expect(rendered).not_to include("ready_to_assign")
  end

  it "doesn't explain in a title or a data-tip, which a keyboard, a touch and a screen reader don't get" do
    render partial: "components/term", locals: { key: :assigned }

    assert_select "[title]", count: 0
    assert_select "[data-tip]", count: 0
  end

  it "puts the tooltip on top unless it's asked to go below, where a table's header would cut it off" do
    render partial: "components/term", locals: { key: :assigned }
    assert_select ".tooltip.tooltip-bottom", count: 0

    render partial: "components/term", locals: { key: :assigned, placement: :bottom }
    assert_select ".tooltip.tooltip-bottom"
  end

  it "can start its tooltip at the term's left edge, for a term at the left of a card, which would be cut off if it were centred on it" do
    render partial: "components/term", locals: { key: :assigned, align: :start }

    assert_select ".tooltip.tooltip-start"
  end

  it "hides the tooltip on a phone, where nothing hovers and a wide one would stick out of the page" do
    render partial: "components/term", locals: { key: :assigned }

    assert_select ".tooltip-content.max-sm\\:hidden"
  end

  describe "around a link or a button that is the term" do
    it "wraps the tooltip around it, described by the sentence, and gives it no tab stop of its own" do
      render inline: <<~ERB
        <%= render "components/term", key: :reallocate do |described_by| %>
          <%= link_to "Reallocate", "/reallocations/new", class: "btn", aria: { describedby: described_by } %>
        <% end %>
      ERB

      assert_select "span.tooltip" do
        assert_select "a.btn[aria-describedby='help-reallocate']", text: "Reallocate"
        assert_select "span.tooltip-content#help-reallocate[role=tooltip]", text: I18n.t("help.reallocate")
        assert_select "[tabindex]", count: 0
      end
    end
  end

  it "does no queries" do
    expect(count_queries { render partial: "components/term", locals: { key: :available } }).to eq(0)
  end

  it "refuses a key that has no sentence, so a typo is an error and not a blank tooltip" do
    expect { render partial: "components/term", locals: { key: :nonsense } }.to raise_error(ActionView::Template::Error, /key not found: :nonsense/)
  end
end
