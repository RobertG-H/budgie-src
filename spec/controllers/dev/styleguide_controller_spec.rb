require "rails_helper"

# The route for this controller only exists in development, so these draw their own. Rendering the views is
# the point: nothing else in the suite reaches the styleguide, and a typo in a partial would only show up
# when a developer opened the page.
RSpec.describe Dev::StyleguideController, type: :controller do
  render_views

  describe "GET /styleguide" do
    context "in development" do
      before { allow(Rails.env).to receive(:development?).and_return(true) }

      it "renders without signing in or having a budget" do
        with_development_routes { get :show }

        expect(response).to have_http_status(:ok)
        assert_select "h1", text: "Styleguide"
      end

      it "has a section for each part of the design" do
        with_development_routes { get :show }

        [ "Colours", "Buttons", "Form fields", "Tables", "Cards", "Month links", "Date range filter", "Record rows", "Link rows", "Sample grid", "Pager", "Alerts and flash", "Empty state", "Modal" ].each do |heading|
          assert_select "section > h2", text: heading
        end
      end

      it "shows month links for the current month, another, the earliest and with the picker" do
        with_development_routes { get :show }

        assert_select "#month-links nav[aria-label=Months]", count: 4
        assert_select "#month-links a[rel=prev]", count: 3
        assert_select "#month-links a[rel=next]", count: 4
        assert_select "#month-links nav a", text: "This month", count: 3
      end

      it "shows Previous disabled, and not a link, for the earliest month" do
        with_development_routes { get :show }

        assert_select "#month-links nav .join > button[disabled][aria-disabled=true]", count: 1
      end

      it "shows the month picker open, in place, with its stepper, its months and This month, beside the live one" do
        with_development_routes { get :show }

        assert_select "#month-links h3", text: "The picker, open"
        assert_select "#month-links div.rounded-box h2", text: "Choose a month"
        assert_select "#month-links div.rounded-box input[type=number][min='1'][max='275760']"
        assert_select "#month-links div.rounded-box a[data-month-picker-target=month]", count: 12
        assert_select "#month-links div.rounded-box a.btn-primary[aria-current=page]", count: 1
        assert_select "#month-links div.rounded-box a[data-month-picker-target=thisMonth]", text: "This month"
      end

      it "shows the month picker, with its twelve months, which is live" do
        with_development_routes { get :show }

        assert_select "#month-links [data-controller='modal month-picker']", count: 1
        assert_select "#month-links dialog.modal [data-month-picker-target=month]", count: 12
        assert_select "#month-links dialog.modal a[data-month-picker-target=thisMonth]", text: "This month"
      end

      it "shows the date range filter with a preset marked, and one for a range that can't be used, with its alert" do
        with_development_routes { get :show }

        assert_select "#date-range-filter form[method=get] input[type=date]", count: 8
        assert_select "#date-range-filter a[aria-current=true]", text: "This month"
        assert_select "#date-range-filter input[type=submit][value=Apply]", count: 4
        assert_select "#date-range-filter [role=alert]", text: /Choose a From and a To date/
        assert_select "#date-range-filter a[aria-current=true]", text: "Any date"
        assert_select "#date-range-filter p", text: "Leave both dates empty for any date."
      end

      it "shows record rows with and without notes, each a link" do
        with_development_routes { get :show }

        assert_select "#record-rows ul.list > li", minimum: 3
        assert_select "#record-rows ul.list li a.list-row", minimum: 3
        assert_select "#record-rows span.block[class~='text-base-content/70']", minimum: 1
        assert_select "#record-rows span.text-right.tabular-nums", text: "$3,000.00"
      end

      it "shows record rows that aren't links, with their year, for what's only read" do
        with_development_routes { get :show }

        assert_select "#record-rows ul.list li div.list-row", minimum: 2
        assert_select "#record-rows span", text: "Sep 12, 2025"
      end

      it "shows the pager in the middle of a list, and at its ends" do
        with_development_routes { get :show }

        assert_select "#pager nav[aria-label=Pages]", count: 3
        assert_select "#pager a[rel=prev]", count: 2
        assert_select "#pager a[rel=next]", count: 2
      end

      it "shows link rows, each a link with its name and a muted line under it" do
        with_development_routes { get :show }

        assert_select "#link-rows ul.list > li", minimum: 2
        assert_select "#link-rows ul.list li a.list-row span.font-semibold", minimum: 2
        assert_select "#link-rows span.block[class~='text-base-content/70']", minimum: 1
      end

      it "shows a sample grid with numbered columns, and a skipped row" do
        with_development_routes { get :show }

        assert_select "#sample-grid table thead th[scope=col]", text: "3"
        assert_select "#sample-grid tbody .badge", text: "Skipped"
      end

      it "shows a file field" do
        with_development_routes { get :show }

        assert_select "#fields input[type=file].file-input"
      end

      it "shows the Ready to Assign card in each of its states, without a database" do
        with_development_routes { get :show }

        assert_select "#cards section.border-warning.bg-warning\\/10 .badge.badge-warning", text: "left to assign"
        assert_select "#cards section:not(.border-warning) .badge.badge-ghost", text: "left to assign"
        assert_select "#cards .badge.badge-success", text: "All assigned"
        assert_select "#cards section.border-error .stat-value .text-error", text: "-$150.00"
        assert_select "#cards section.border-error .text-error", text: "More was assigned than deposited."
        assert_select "#cards section span", text: "Nothing to assign yet."
        assert_select "#cards section dl dt", text: "Reallocated", count: 1
      end

      it "shows the Ready to Assign card as a card with a plain link, not one big link" do
        with_development_routes { get :show }

        assert_select "#cards section a", text: "See Deposits", minimum: 1
        assert_select "#cards a.stats", count: 0
        assert_select "#cards a .stat-value", count: 0
      end

      it "shows a field whose label is hidden from sight but not from assistive technology" do
        with_development_routes { get :show }

        assert_select "#fields label.sr-only", text: "Assigned to Groceries in September 2026"
        assert_select "#fields input[type=number][aria-describedby$=_hint]"
      end

      it "shows every theme role next to its content colour" do
        with_development_routes { get :show }

        assert_select "#colours .rounded-box", count: 11
        %w[ base-100 base-200 base-300 primary secondary accent neutral info success warning error ].each do |role|
          content = role.start_with?("base") ? "base-content" : "#{role}-content"

          assert_select "#colours .rounded-box p", text: role
          assert_select "#colours .rounded-box p", text: content
        end
      end

      it "shows fields with a hint and with an error, and the error summary" do
        with_development_routes { get :show }

        assert_select "#fields input[type=text]"
        assert_select "#fields input[type=number][step='0.01']"
        assert_select "#fields select"
        assert_select "#fields textarea"
        assert_select "#fields input[type=checkbox]"
        assert_select "#fields p[id$=_hint]"
        assert_select "#fields input[aria-invalid=true][aria-describedby$=_error]"
        assert_select "#fields [role=alert] li", text: "Name can't be blank"
      end

      it "shows a group of radio buttons under a legend, with a hint" do
        with_development_routes { get :show }

        assert_select "#fields fieldset > legend", text: "Favourite colour"
        assert_select "#fields fieldset input.radio[type=radio]", minimum: 2
        assert_select "#fields fieldset p[id$=_hint]"
      end

      it "shows the delete button, which asks first, and with another label, such as Undo" do
        with_development_routes { get :show }

        assert_select "#buttons form[data-turbo-confirm] button.btn-ghost.text-error", text: "Delete"
        assert_select "#buttons form[data-turbo-confirm] button.btn-ghost.text-error", text: "Undo"
      end

      it "shows the label badge, in a row that isn't a link" do
        with_development_routes { get :show }

        assert_select "#record-rows li div.list-row .badge", text: "Ignored"
      end

      it "shows money columns, with a negative Available that says Overspent" do
        with_development_routes { get :show }

        assert_select "#tables th", text: "Assigned"
        assert_select "#tables th", text: "Spent"
        assert_select "#tables th", text: "Available"
        assert_select "#tables td.text-right.tabular-nums", minimum: 6
        assert_select "#tables tbody tr:last-child td:last-child", text: /-\$30\.00\s+Overspent/
      end

      it "shows a term, a tooltip on a header, a card and a button, and the same words in a <details>" do
        with_development_routes { get :show }

        assert_select "#terms [aria-describedby='help-carried-over'][tabindex='0']", text: "Carried over"
        assert_select "#terms th .tooltip.tooltip-bottom [role=tooltip]", count: 2
        assert_select "#terms .stat-title .tooltip.tooltip-start"
        assert_select "#terms a.btn[aria-describedby='help-reallocate']", text: "Reallocate"
        assert_select "#terms .tooltip form button[aria-describedby='help-archive']", text: "Archive"
        assert_select "#terms details summary", text: "What do these figures mean?"
        ids = css_select("[role=tooltip]").map { |tip| tip["id"] }
        expect(ids).to eq(ids.uniq)
      end

      it "shows a stat card, all four flash types, an empty state and a modal" do
        with_development_routes { get :show }

        assert_select ".stat-title", text: "Ready to Assign"
        assert_select ".stat-value", text: "$1,250.00"
        assert_select "#alerts [role=status]", count: 3
        assert_select "#alerts [role=status] a.link", text: "Review them"
        assert_select "#alerts [role=alert]", count: 2
        assert_select "#empty-states p", text: "You don't have any envelopes yet."
        assert_select "#modals [data-controller=modal] dialog.modal[data-modal-target=dialog]"
      end
    end

    context "outside development" do
      it "is not found" do
        with_development_routes { get :show }

        expect(response).to have_http_status(:not_found)
        assert_select "h1", count: 0
      end
    end
  end
end
