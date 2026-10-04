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

        [ "Colours", "Buttons", "Form fields", "Tables", "Cards", "Month links", "Record rows", "Alerts and flash", "Empty state", "Modal" ].each do |heading|
          assert_select "section > h2", text: heading
        end
      end

      it "shows month links for the current month and for another, which can go back to this month" do
        with_development_routes { get :show }

        assert_select "#month-links nav[aria-label=Months]", count: 2
        assert_select "#month-links a[rel=prev]", count: 2
        assert_select "#month-links a[rel=next]", count: 2
        assert_select "#month-links a", text: "This month", count: 1
      end

      it "shows record rows with and without notes, each a link" do
        with_development_routes { get :show }

        assert_select "#record-rows ul.list > li", minimum: 3
        assert_select "#record-rows ul.list li a.list-row", minimum: 3
        assert_select "#record-rows span.block[class~='text-base-content/70']", minimum: 1
        assert_select "#record-rows span.text-right.tabular-nums", text: "$3,000.00"
      end

      it "shows a stat card that links to the records behind its number" do
        with_development_routes { get :show }

        assert_select "#cards a.stats[href] .stat-title", text: "Ready to Assign"
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

      it "shows the delete button, which asks first" do
        with_development_routes { get :show }

        assert_select "#buttons form[data-turbo-confirm] button.btn-ghost.text-error", text: "Delete"
      end

      it "shows money columns, with a negative Available that says Overspent" do
        with_development_routes { get :show }

        assert_select "#tables th", text: "Assigned"
        assert_select "#tables th", text: "Spent"
        assert_select "#tables th", text: "Available"
        assert_select "#tables td.text-right.tabular-nums", minimum: 6
        assert_select "#tables tbody tr:last-child td:last-child", text: /-\$30\.00\s+Overspent/
      end

      it "shows a stat card, all four flash types, an empty state and a modal" do
        with_development_routes { get :show }

        assert_select ".stat-title", text: "Ready to Assign"
        assert_select ".stat-value", text: "$1,250.00"
        assert_select "#alerts [role=status]", count: 2
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
