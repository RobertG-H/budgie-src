require "rails_helper"

RSpec.describe "Envelopes", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }

  before { sign_in_as budget.user }

  describe "GET /months/:month/envelopes/:id" do
    let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 250) }

    # What each listed Spend shows, as one line of text apiece.
    def rows
      css_select("ul.list li").map { |row| row.text.squish }
    end

    it "is headed with the envelope's name, the month as its description, and New spend, New refund, Edit and Delete as its actions" do
      get month_envelope_path("2026-09", groceries)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Groceries · September 2026 · Budgie"
      assert_select "h1", text: "Groceries"
      assert_select "h1 + p", text: "September 2026"
      assert_select "a.btn.btn-primary[href='#{new_spend_path(month: "2026-09", from: "envelope", envelope: groceries.id)}']", text: "New spend"
      assert_select "a.btn[href='#{new_refund_path(month: "2026-09", from: "envelope", envelope: groceries.id)}']", text: "New refund"
      assert_select "a.btn-primary", count: 1
      assert_select "a.btn[href='#{edit_envelope_path(groceries, month: "2026-09", from: "envelope")}']", text: "Edit"
      assert_select "form[action='#{envelope_path(groceries)}'][data-turbo-confirm='Delete the Groceries envelope?']" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "input[name=month][value='2026-09']"
        assert_select "button", text: "Delete"
      end
    end

    it "shows what it carried over, what's Assigned to it, Spent from it and Refunded to it in the month, and what's Available, in that order" do
      get month_envelope_path("2026-09", groceries)

      expect(css_select(".stat-title").map { |title| title.text.strip }).to eq([ "Carried over", "Assigned", "Spent", "Refunded", "Available" ])
      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "$250.00", "$0.00", "$0.00", "$0.00", "$250.00" ])
      assert_select ".badge", count: 0
    end

    it "shows the month's own Assigned, and what it adds to Available, with what was assigned before it carried over" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 8, 1), amount: 40)
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 1234.5)
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 10, 1), amount: 999)

      get month_envelope_path("2026-09", groceries)

      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "$290.00", "$1,234.50", "$0.00", "$0.00", "$1,524.50" ])
    end

    it "shows what's Spent in the month, and takes what was Spent before it out of what it carried over" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 400)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 8, 31), amount: 60)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 1), amount: 100.25)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 30), amount: 50)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 10, 1), amount: 999)

      get month_envelope_path("2026-09", groceries)

      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "$190.00", "$400.00", "$150.25", "$0.00", "$439.75" ])
    end

    it "shows what's Refunded in the month, which raises Available, and takes what was Refunded before it into what it carried over" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 400)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 12), amount: 100)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 8, 31), amount: 15)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 9, 1), amount: 24.5)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 9, 30), amount: 10)
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 10, 1), amount: 999)

      get month_envelope_path("2026-09", groceries)

      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "$265.00", "$400.00", "$100.00", "$34.50", "$599.50" ])
    end

    it "gives the Groceries example in January, February and March, with February Overspent" do
      envelope = create(:budget_envelope, budget: budget, name: "Weekly groceries", starting_balance: 0)
      [ "2026-01-01", "2026-02-01", "2026-03-01" ].each { |month| create(:budget_assignment, envelope: envelope, month: month, amount: 400) }
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 1, 20), amount: 350)
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 2, 14), amount: 480)
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 3, 3), amount: 300)

      shown = [ "2026-01", "2026-02", "2026-03" ].map do |month|
        get month_envelope_path(month, envelope)
        [ css_select(".stat-value").map { |value| value.text.squish }, css_select(".badge").size ]
      end

      expect(shown).to eq([
        [ [ "$0.00", "$400.00", "$350.00", "$0.00", "$50.00" ], 0 ],
        [ [ "$50.00", "$400.00", "$480.00", "$0.00", "-$30.00 Overspent" ], 1 ],
        [ [ "-$30.00", "$400.00", "$300.00", "$0.00", "$70.00" ], 0 ]
      ])
    end

    it "gives the Groceries example with a $50 Refund in February, which is no longer Overspent" do
      envelope = create(:budget_envelope, budget: budget, name: "Weekly groceries", starting_balance: 0)
      [ "2026-01-01", "2026-02-01", "2026-03-01" ].each { |month| create(:budget_assignment, envelope: envelope, month: month, amount: 400) }
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 1, 20), amount: 350)
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 2, 14), amount: 480)
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 3, 3), amount: 300)
      create(:budget_refund, envelope: envelope, date: Date.new(2026, 2, 20), amount: 50)

      shown = [ "2026-01", "2026-02", "2026-03" ].map do |month|
        get month_envelope_path(month, envelope)
        [ css_select(".stat-value").map { |value| value.text.squish }, css_select(".badge").size ]
      end

      expect(shown).to eq([
        [ [ "$0.00", "$400.00", "$350.00", "$0.00", "$50.00" ], 0 ],
        [ [ "$50.00", "$400.00", "$480.00", "$50.00", "$20.00" ], 0 ],
        [ [ "$20.00", "$400.00", "$300.00", "$0.00", "$120.00" ], 0 ]
      ])
    end

    it "lists exactly its own Spends dated in the month, the newest first, and no one else's" do
      create(:budget_spend, envelope: groceries, description: "First of the month", date: Date.new(2026, 9, 1), amount: 10)
      create(:budget_spend, envelope: groceries, description: "End of the month", date: Date.new(2026, 9, 30), amount: 20.5)
      create(:budget_spend, envelope: groceries, description: "Month before", date: Date.new(2026, 8, 31))
      create(:budget_spend, envelope: groceries, description: "Month after", date: Date.new(2026, 10, 1))
      create(:budget_spend, envelope: create(:budget_envelope, budget: budget), description: "Another envelope's", date: Date.new(2026, 9, 5))
      create(:budget_spend, envelope: others_envelope, description: "Someone else's", date: Date.new(2026, 9, 5))

      get month_envelope_path("2026-09", groceries)

      expect(rows).to eq([ "Sep 30 End of the month $20.50", "Sep 1 First of the month $10.00" ])
      expect(response.body).not_to include("Someone else")
    end

    it "has a Spends heading over the list, and shows each Spend's date, description, notes and amount, linking to where it's edited" do
      loblaws = create(:budget_spend, envelope: groceries, description: "Loblaws", date: Date.new(2026, 9, 30), amount: 123.45, notes: "Weekly shop")
      bare = create(:budget_spend, envelope: groceries, description: "Corner store", date: Date.new(2026, 9, 5), amount: 4)

      get month_envelope_path("2026-09", groceries)

      assert_select "h2", text: "Spends"
      assert_select "ul.list li a[href='#{edit_spend_path(loblaws, month: "2026-09", from: "envelope")}']" do
        assert_select "span", text: "Sep 30"
        assert_select "span", text: "Loblaws"
        assert_select "span[class~='text-base-content/70']", text: "Weekly shop"
        assert_select "span.text-right", text: "$123.45"
      end
      assert_select "ul.list li a[href='#{edit_spend_path(bare, month: "2026-09", from: "envelope")}']" do
        assert_select "span.text-right", text: "$4.00"
        assert_select "span.block[class~='text-base-content/70']", count: 0
      end
    end

    it "lists the Spends of the month it's opened for, whichever it is" do
      create(:budget_spend, envelope: groceries, description: "In August", date: Date.new(2026, 8, 31))
      create(:budget_spend, envelope: groceries, description: "In September", date: Date.new(2026, 9, 1))

      get month_envelope_path("2026-08", groceries)
      expect(rows).to eq([ "Aug 31 In August $100.00" ])

      get month_envelope_path("2026-09", groceries)
      expect(rows).to eq([ "Sep 1 In September $100.00" ])
    end

    it "says when there are none in the month, even when there are in other months" do
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 8, 31))

      get month_envelope_path("2026-09", groceries)

      assert_select "h2", text: "Spends"
      assert_select "ul.list", count: 0
      assert_select "main p", text: "No spends in September 2026."
    end

    it "lists its Refunds below its Spends, in the same way, exactly those dated in the month, the newest first, and no one else's" do
      create(:budget_spend, envelope: groceries, description: "Loblaws", date: Date.new(2026, 9, 3), amount: 80)
      ikea = create(:budget_refund, envelope: groceries, description: "IKEA return", date: Date.new(2026, 9, 30), amount: 123.45, notes: "Bookcase")
      create(:budget_refund, envelope: groceries, description: "Loblaws return", date: Date.new(2026, 9, 1), amount: 10)
      create(:budget_refund, envelope: groceries, description: "Month before", date: Date.new(2026, 8, 31))
      create(:budget_refund, envelope: groceries, description: "Month after", date: Date.new(2026, 10, 1))
      create(:budget_refund, envelope: create(:budget_envelope, budget: budget), description: "Another envelope's", date: Date.new(2026, 9, 5))
      create(:budget_refund, envelope: others_envelope, description: "Someone else's", date: Date.new(2026, 9, 5))

      get month_envelope_path("2026-09", groceries)

      expect(css_select("h2").map { |heading| heading.text.strip }).to eq([ "Spends", "Refunds" ])
      expect(css_select("ul.list").map { |list| list.css("li").map { |row| row.text.squish } }).to eq([
        [ "Sep 3 Loblaws $80.00" ],
        [ "Sep 30 IKEA return Bookcase $123.45", "Sep 1 Loblaws return $10.00" ]
      ])
      assert_select "ul.list li a[href='#{edit_refund_path(ikea, month: "2026-09", from: "envelope")}']" do
        assert_select "span", text: "IKEA return"
        assert_select "span.text-right", text: "$123.45"
      end
      expect(response.body).not_to include("Someone else")
    end

    it "has no Refunds section when the month has no Refunds, even when other months have, and no empty message for it" do
      create(:budget_refund, envelope: groceries, date: Date.new(2026, 8, 31))

      get month_envelope_path("2026-09", groceries)

      assert_select "h2", text: "Refunds", count: 0
      assert_select "h2", text: "Spends"
      expect(response.body).not_to match(/no refunds/i)
    end

    it "lists the Refunds of the month it's opened for, whichever it is" do
      create(:budget_refund, envelope: groceries, description: "In August", date: Date.new(2026, 8, 31))
      create(:budget_refund, envelope: groceries, description: "In September", date: Date.new(2026, 9, 1))

      get month_envelope_path("2026-08", groceries)
      expect(rows).to eq([ "Aug 31 In August $100.00" ])

      get month_envelope_path("2026-09", groceries)
      expect(rows).to eq([ "Sep 1 In September $100.00" ])
    end

    it "shows what's Assigned, with a way back to the month view to change it, and no input of its own for it" do
      get month_envelope_path("2026-09", groceries)

      assert_select "a[href='#{month_path("2026-09")}']", text: "Back to September 2026"
      assert_select "input[name='assignment[amount]']", count: 0
      assert_select "turbo-frame", count: 0
    end

    it "says Overspent when Available is below zero" do
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)

      get month_envelope_path("2031-12", bills)

      assert_select ".stat-value", text: "-$30.00", count: 1
      assert_select ".stat-value", text: /-\$30\.00\s+Overspent/, count: 1
      assert_select ".badge", text: "Overspent", count: 1
    end

    it "says Overspent when what's Spent takes Available below zero" do
      create(:budget_assignment, envelope: groceries, month: Date.new(2026, 9, 1), amount: 100)
      create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 12), amount: 400)

      get month_envelope_path("2026-09", groceries)

      expect(css_select(".stat-value").map { |value| value.text.squish }).to eq([ "$250.00", "$100.00", "$400.00", "$0.00", "-$50.00 Overspent" ])
      assert_select ".badge", text: "Overspent", count: 1
    end

    it "stops saying Overspent once enough is assigned to cover it" do
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      create(:budget_assignment, envelope: bills, month: Date.new(2031, 12, 1), amount: 30)

      get month_envelope_path("2031-12", bills)

      assert_select ".badge", count: 0
      expect(css_select(".stat-value").map { |value| value.text.strip }).to eq([ "-$30.00", "$30.00", "$0.00", "$0.00", "$0.00" ])
    end

    it "has month links that stay on this envelope, and a link back to the month view" do
      travel_to Time.utc(2026, 9, 15, 16)

      get month_envelope_path("2026-09", groceries)

      assert_select "nav[aria-label=Months] a[href='#{month_envelope_path("2026-08", groceries)}']", text: "August 2026"
      assert_select "nav[aria-label=Months] a[href='#{month_envelope_path("2026-10", groceries)}']", text: "October 2026"
      assert_select "a[href='#{month_path("2026-09")}']", text: "Back to September 2026"

      get month_envelope_path("2027-03", groceries)

      assert_select "nav[aria-label=Months] a[href='#{month_envelope_path("2026-09", groceries)}']", text: "This month"
    end

    it "is not found for another user's envelope" do
      get month_envelope_path("2026-09", others_envelope)

      expect(response).to have_http_status(:not_found)
    end

    it "is not found for an envelope that doesn't exist, or a month that isn't one" do
      get month_envelope_path("2026-09", 0)
      expect(response).to have_http_status(:not_found)

      get "/months/2026-09/envelopes/not-an-id"
      expect(response).to have_http_status(:not_found)

      get "/months/2026-13/envelopes/#{groceries.id}"
      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get month_envelope_path("2026-09", groceries)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "the list of envelopes" do
    it "is gone: envelopes are created from the month view, and edited and deleted from their page" do
      get "/envelopes"
      expect(response).to have_http_status(:not_found)

      get "/envelopes/#{create(:budget_envelope, budget: budget).id}"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /envelopes/new" do
    it "shows the form, remembering the page and month it was opened from" do
      get new_envelope_path(month: "2026-09", from: "month")

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "New envelope"
      assert_select "form[action='#{envelopes_path}'] input[name='envelope[name]']"
      assert_select "form input[type=number][name='envelope[starting_balance]'][step='0.01']"
      assert_select "label", text: "Starting balance"
      assert_select "form input[type=hidden][name=from][value=month]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
    end

    it "has a Cancel link back to the month it was opened from" do
      get new_envelope_path(month: "2026-09", from: "month")

      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "is not found for a month that isn't one" do
      get new_envelope_path(month: "2026-13")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /envelopes" do
    it "creates an envelope in the user's budget, and goes back to the month it was opened from" do
      expect { post envelopes_path, params: { envelope: { name: " Groceries ", starting_balance: "-12.34" }, from: "month", month: "2027-03" } }
        .to change(budget.envelopes, :count).by(1)

      expect(budget.envelopes.sole).to have_attributes(name: "Groceries", starting_balance: BigDecimal("-12.34"))
      expect(response).to redirect_to(month_path("2027-03"))
      follow_redirect!
      assert_select "[role=status]", text: "Envelope created."
    end

    it "goes to the current month when it wasn't opened from one" do
      travel_to Time.utc(2026, 9, 15, 16)

      post envelopes_path, params: { envelope: { name: "Groceries" } }

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "saves a blank starting balance as 0" do
      post envelopes_path, params: { envelope: { name: "Groceries", starting_balance: "" } }

      expect(budget.envelopes.sole.starting_balance).to eq(0)
    end

    it "shows errors for an invalid envelope, and remembers where the form was opened from" do
      create(:budget_envelope, budget: budget, name: "Groceries")

      expect { post envelopes_path, params: { envelope: { name: "groceries", starting_balance: "1.234" }, from: "month", month: "2026-09" } }
        .not_to change(Budget::Envelope, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name has already been taken"
      assert_select "[role=alert] li", text: "Starting balance can't have more than 2 decimal places"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "ignores a budget_id in the params" do
      other_budget = create(:budget)

      post envelopes_path, params: { envelope: { name: "Groceries", budget_id: other_budget.id } }

      expect(budget.envelopes.sole.name).to eq("Groceries")
      expect(other_budget.envelopes).to be_empty
    end
  end

  describe "GET /envelopes/:id/edit" do
    let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 50) }

    it "shows the form for the user's envelope" do
      get edit_envelope_path(groceries, month: "2026-09", from: "envelope")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit Groceries · Budgie"
      assert_select "h1", text: "Edit envelope"
      assert_select "form[action='#{envelope_path(groceries)}'] input[name='envelope[name]'][value=Groceries]"
      assert_select "form input[type=hidden][name=from][value=envelope]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
    end

    it "has a Cancel link back to the envelope's page, for the month it was opened from" do
      get edit_envelope_path(groceries, month: "2026-09", from: "envelope")

      assert_select "a.btn[href='#{month_envelope_path("2026-09", groceries)}']", text: "Cancel"
    end

    it "is not found for another user's envelope" do
      get edit_envelope_path(others_envelope)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /envelopes/:id" do
    let(:envelope) { create(:budget_envelope, budget: budget, name: "Groceries", starting_balance: 50) }

    it "updates the name and starting balance, and goes back to the envelope's page for the month it was opened from" do
      patch envelope_path(envelope), params: { envelope: { name: "Food", starting_balance: "-5" }, from: "envelope", month: "2027-03" }

      expect(envelope.reload).to have_attributes(name: "Food", starting_balance: -5)
      expect(response).to redirect_to(month_envelope_path("2027-03", envelope))
      follow_redirect!
      assert_select "[role=status]", text: "Envelope updated."
      assert_select "h1", text: "Food"
    end

    it "goes back to the month view when it was opened from there, or from something that isn't a page" do
      [ "month", "https://evil.example/", "//evil.example", nil ].each do |from|
        patch envelope_path(envelope), params: { envelope: { name: "Food" }, from: from, month: "2026-09" }

        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "shows errors for an invalid change, and remembers where the form was opened from" do
      patch envelope_path(envelope), params: { envelope: { name: " " }, from: "envelope", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"
      assert_select "a.btn[href='#{month_envelope_path("2026-09", envelope)}']", text: "Cancel"
      expect(envelope.reload.name).to eq("Groceries")
    end

    it "doesn't move the envelope to another budget" do
      other_budget = create(:budget)

      patch envelope_path(envelope), params: { envelope: { name: "Food", budget_id: other_budget.id } }

      expect(envelope.reload.budget).to eq(budget)
    end

    it "is not found for another user's envelope, which stays unchanged" do
      patch envelope_path(others_envelope), params: { envelope: { name: "Mine now" } }

      expect(response).to have_http_status(:not_found)
      expect(others_envelope.reload.name).to eq("Someone else's")
    end
  end

  describe "DELETE /envelopes/:id" do
    it "deletes the user's envelope, and goes to the month view for the month it was opened from" do
      envelope = create(:budget_envelope, budget: budget)

      expect { delete envelope_path(envelope), params: { month: "2027-03" } }.to change(Budget::Envelope, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_path("2027-03"))
      follow_redirect!
      assert_select "[role=status]", text: "Envelope deleted."
    end

    it "refuses to delete an envelope with Assigned amounts, says why on the envelope's page, and keeps both" do
      envelope = create(:budget_envelope, budget: budget, name: "Groceries")
      create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }
        .to not_change(Budget::Envelope, :count).and not_change(Budget::Assignment, :count)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_envelope_path("2026-09", envelope))
      follow_redirect!
      assert_select "[role=alert]", text: "This envelope can't be deleted because it has records."
      assert_select "[role=status]", count: 0
      assert_select "h1", text: "Groceries"
    end

    it "stays on the same month's page for the envelope when it refuses" do
      envelope = create(:budget_envelope, budget: budget)
      create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      delete envelope_path(envelope), params: { from: "envelope", month: "2027-03" }

      expect(response).to redirect_to(month_envelope_path("2027-03", envelope))
    end

    it "refuses to delete an envelope with Spends, says why on the envelope's page, and keeps both" do
      envelope = create(:budget_envelope, budget: budget, name: "Groceries")
      create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 12), amount: 100)

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }
        .to not_change(Budget::Envelope, :count).and not_change(Budget::Spend, :count)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_envelope_path("2026-09", envelope))
      follow_redirect!
      assert_select "[role=alert]", text: "This envelope can't be deleted because it has records."
      assert_select "[role=status]", count: 0
      assert_select "h1", text: "Groceries"
      expect(response.body).not_to include("PG::")
    end

    it "refuses to delete an envelope with Refunds, says why on the envelope's page, and keeps both" do
      envelope = create(:budget_envelope, budget: budget, name: "Groceries")
      create(:budget_refund, envelope: envelope, date: Date.new(2026, 9, 12), amount: 100)

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }
        .to not_change(Budget::Envelope, :count).and not_change(Budget::Refund, :count)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_envelope_path("2026-09", envelope))
      follow_redirect!
      assert_select "[role=alert]", text: "This envelope can't be deleted because it has records."
      assert_select "[role=status]", count: 0
      assert_select "h1", text: "Groceries"
      expect(response.body).not_to include("PG::")
    end

    it "deletes it once its Refunds are deleted" do
      envelope = create(:budget_envelope, budget: budget)
      refund = create(:budget_refund, envelope: envelope, date: Date.new(2026, 9, 12))

      refund.destroy!

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }.to change(Budget::Envelope, :count).by(-1)
      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "deletes it once its Spends are deleted" do
      envelope = create(:budget_envelope, budget: budget)
      spend = create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 12))

      spend.destroy!

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }.to change(Budget::Envelope, :count).by(-1)
      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "deletes it once its Assigned amounts are cleared" do
      envelope = create(:budget_envelope, budget: budget)
      assignment = create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      assignment.destroy!

      expect { delete envelope_path(envelope), params: { month: "2026-09" } }.to change(Budget::Envelope, :count).by(-1)
      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "doesn't let the database's own refusal become the way an envelope with records is turned down" do
      envelope = create(:budget_envelope, budget: budget)
      create(:budget_assignment, envelope: envelope, month: Date.new(2026, 9, 1), amount: 100)

      delete envelope_path(envelope), params: { month: "2026-09" }

      expect(response).to have_http_status(:see_other)
      expect(response.body).not_to include("PG::")
    end

    it "goes to the month view even when it was opened from the envelope's own page, which is gone" do
      envelope = create(:budget_envelope, budget: budget)

      delete envelope_path(envelope), params: { from: "envelope", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is not found for another user's envelope, which isn't deleted" do
      others_envelope

      expect { delete envelope_path(others_envelope) }.not_to change(Budget::Envelope, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
