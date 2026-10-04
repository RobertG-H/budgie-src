require "rails_helper"

# Small partials whose one job is an optional block: what the block holds appears, and an empty block
# doesn't leave an empty wrapper behind.
RSpec.describe "components", type: :view do
  describe "_page_header" do
    it "is the page's h1" do
      render inline: %(<%= render "components/page_header", title: "Envelopes" %>)

      assert_select "h1", text: "Envelopes"
      assert_select "p", count: 0
    end

    it "shows a description under the title" do
      render inline: %(<%= render "components/page_header", title: "Set up", description: "Pick one." %>)

      assert_select "p", text: "Pick one."
    end

    it "shows the block as actions beside the title" do
      render inline: <<~ERB
        <%= render "components/page_header", title: "Envelopes" do %><a href="/new">New envelope</a><% end %>
      ERB

      assert_select "h1", text: "Envelopes"
      assert_select "a[href='/new']", text: "New envelope"
    end
  end

  describe "_empty_state" do
    it "says what's missing, with nothing else" do
      render inline: %(<%= render "components/empty_state", message: "You don't have any envelopes yet." %>)

      assert_select "p", text: "You don't have any envelopes yet."
      assert_select "p", count: 1
      assert_select "a, button", count: 0
    end

    it "can have a title and something to do next" do
      render inline: <<~ERB
        <%= render "components/empty_state", title: "No envelopes", message: "Create one." do %><a href="/new">New envelope</a><% end %>
      ERB

      assert_select "p.font-semibold", text: "No envelopes"
      assert_select "p", text: "Create one."
      assert_select "a[href='/new']", text: "New envelope"
    end
  end

  describe "_stat_card" do
    it "shows a title and a value, and a description when there is one" do
      render inline: %(<%= render "components/stat_card", title: "Ready to Assign", value: "$1,250.00" %>)
      assert_select ".stat-title", text: "Ready to Assign"
      assert_select ".stat-value", text: "$1,250.00"
      assert_select ".stat-desc", count: 0

      render inline: %(<%= render "components/stat_card", title: "Ready to Assign", value: "$1,250.00", description: "Across 3 envelopes" %>)
      assert_select ".stat-desc", text: "Across 3 envelopes"
    end

    it "says what's wrong in words, under the description and in the error colour, when given an error" do
      render inline: <<~ERB
        <%= render "components/stat_card", title: "Ready to Assign", value: "-$150.00", description: "Assigned $250.00", error: "More was assigned than deposited." %>
      ERB

      assert_select ".stat-desc", count: 2
      assert_select ".stat-desc:not(.text-error)", text: "Assigned $250.00"
      assert_select ".stat-desc.text-error", text: "More was assigned than deposited."
    end

    it "can have an error without a description, and has none when it isn't given one" do
      render inline: %(<%= render "components/stat_card", title: "Ready to Assign", value: "-$1.00", error: "Too much." %>)
      assert_select ".stat-desc.text-error", text: "Too much."
      assert_select ".stat-desc", count: 1

      render inline: %(<%= render "components/stat_card", title: "Ready to Assign", value: "$1.00", description: "Fine." %>)
      assert_select ".stat-desc.text-error", count: 0
    end

    it "lets what's under the number wrap, so a long description doesn't run off a narrow card" do
      render inline: %(<%= render "components/stat_card", title: "Ready to Assign", value: "$1.00", description: "Carried over $1 · Deposited $2 · Assigned $3", error: "Wrong." %>)

      assert_select ".stat-desc.whitespace-normal", count: 2
    end

    it "lets the number wrap too, so a badge beside it, such as Overspent, drops under it in a narrow card instead of being cut off" do
      render inline: %(<%= render "components/stat_card", title: "Available", value: "-$30.00 Overspent" %>)

      assert_select ".stat-value.whitespace-normal", text: "-$30.00 Overspent"
    end

    it "isn't a link unless it's given somewhere to go" do
      render inline: %(<%= render "components/stat_card", title: "Ready to Assign", value: "$1,250.00" %>)

      assert_select "a", count: 0
      assert_select "div.stats .stat-title", text: "Ready to Assign"
    end

    it "links the whole card to the records behind its number when given an href" do
      render inline: <<~ERB
        <%= render "components/stat_card", title: "Ready to Assign", value: "$1,250.00", description: "Deposited $1,250.00", href: "/months/2026-09/deposits" %>
      ERB

      assert_select "a.stats[href='/months/2026-09/deposits']", count: 1
      assert_select "a.stats .stat-title", text: "Ready to Assign"
      assert_select "a.stats .stat-value", text: "$1,250.00"
      assert_select "a.stats .stat-desc", text: "Deposited $1,250.00"
    end
  end

  describe "_record_list" do
    it "is a bordered list holding the block, which is the rows" do
      render inline: <<~ERB
        <%= render "components/record_list" do %><li>First</li><li>Second</li><% end %>
      ERB

      assert_select "ul.list.rounded-box.border > li", count: 2
      assert_select "ul.list > li:first-child", text: "First"
    end
  end

  describe "_modal" do
    before do
      render inline: <<~ERB
        <%= render "components/modal", title: "Modal title", trigger: "Open modal" do %><p>Content</p><% end %>
      ERB
    end

    it "opens a native dialog through the modal Stimulus controller" do
      assert_select "[data-controller=modal] button[data-action='modal#open']", text: "Open modal"
      assert_select "[data-controller=modal] dialog.modal[data-modal-target=dialog][data-action='click->modal#closeOnBackdrop']"
    end

    it "names the dialog after its title, and holds the block and a Close button" do
      title_id = css_select("dialog h2").first["id"]

      assert_select "dialog[aria-labelledby=?]", title_id
      assert_select "dialog h2", text: "Modal title"
      assert_select "dialog .modal-box p", text: "Content"
      assert_select "dialog form[method=dialog] button", text: "Close"
    end
  end
end
