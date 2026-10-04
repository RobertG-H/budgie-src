require "rails_helper"

RSpec.describe "Months", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }

  before { sign_in_as budget.user }

  # The words under Ready to Assign's number. Its amounts are spans of their own, so the whitespace between the
  # pieces is collapsed before comparing.
  def stat_description
    css_select(".stat-desc").map { |description| description.text.squish }.sole
  end

  describe "GET /" do
    it "opens the current month, by Eastern time" do
      # 00:30 UTC on October 1 is still the evening of September 30 in Eastern time.
      travel_to Time.utc(2026, 10, 1, 0, 30)

      get root_path

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "September 2026"
      assert_select "title", text: "September 2026 · Budgie"
    end

    it "is the month view for a user who has a budget, and nothing else" do
      get root_path

      expect(response).to have_http_status(:ok)
      assert_select "h1", count: 1
    end
  end

  describe "GET /months/:month" do
    it "shows the month it names, whatever today is" do
      get month_path("2031-02")

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "February 2031"
      assert_select "title", text: "February 2031 · Budgie"
    end

    it "isn't bounded in either direction" do
      get month_path("0001-01")
      expect(response).to have_http_status(:ok)

      get month_path("9999-12")
      expect(response).to have_http_status(:ok)
      assert_select "nav[aria-label=Months] a[rel=next]", text: "January 10000"

      click_next = css_select("nav[aria-label=Months] a[rel=next]").first["href"]
      get click_next
      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "January 10000"
    end

    [ "2026-13", "2026-00", "2026-9", "2026-09-01", "0000-05", "1000000-01", "abc" ].each do |param|
      it "is not found for #{param.inspect}, which isn't a month" do
        get "/months/#{param}"

        expect(response).to have_http_status(:not_found)
      end
    end

    it "requires sign-in" do
      delete session_path

      get month_path("2026-09")

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "Ready to Assign" do
    it "is every Deposit for the month and before it, with what was carried over and deposited, linking to the month's Deposits" do
      create(:budget_deposit, budget: budget, amount: 1000, date: Date.new(2026, 8, 1))
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 1))
      create(:budget_deposit, budget: budget, amount: 777, date: Date.new(2026, 10, 1))
      create(:budget_deposit, amount: 999, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select "a[href='#{month_deposits_path("2026-09")}']" do
        assert_select ".stat-title", text: "Ready to Assign"
        assert_select ".stat-value", text: "$4,000.00"
        expect(stat_description).to eq("Carried over $1,000.00 · Deposited $3,000.00")
      end
    end

    it "shows the amounts it's described with the way every amount is shown, so a negative would be signed and red" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select ".stat-desc span", count: 2
      assert_select ".stat-desc span", text: "$0.00"
      assert_select ".stat-desc span", text: "$3,000.00"
    end

    it "is $0.00 for a budget with no Deposits" do
      get month_path("2026-09")

      assert_select ".stat-value", text: "$0.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $0.00")
    end

    it "carries forward into a month with no Deposits of its own" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 7, 1))

      get month_path("2026-12")

      assert_select ".stat-value", text: "$3,000.00"
      expect(stat_description).to eq("Carried over $3,000.00 · Deposited $0.00")
    end

    it "counts a Deposit dated September 30 and marked for October in October, and not in September" do
      create(:budget_deposit, budget: budget, amount: 3000, date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))

      get month_path("2026-09")
      expect(stat_description).to eq("Carried over $0.00 · Deposited $0.00")

      get month_path("2026-10")
      assert_select ".stat-value", text: "$3,000.00"
      expect(stat_description).to eq("Carried over $0.00 · Deposited $3,000.00")
    end

    it "is shown in the budget's currency unit" do
      budget.update!(currency: "GBP")
      create(:budget_deposit, budget: budget, amount: 25, date: Date.new(2026, 9, 1))

      get month_path("2026-09")

      assert_select ".stat-value", text: "£25.00"
    end
  end

  describe "the header" do
    it "links Budgie to the home page and shows the budget's currency once" do
      get month_path("2026-09")

      assert_select "header a[href='/']", text: "Budgie"
      assert_select "header", text: /Budget in CAD/
      expect(response.body.scan("CAD").size).to eq(1)
    end

    it "keeps only Sign out in the main navigation" do
      create(:budget_envelope, budget: budget)

      get month_path("2026-09")

      assert_select "nav[aria-label=Main] form[action='#{session_path}'] button", text: "Sign out"
      assert_select "nav[aria-label=Main] a", count: 0
    end
  end

  describe "the envelopes" do
    it "are listed alphabetically, each name linking to its page, with Carried over and Available" do
      rent = create(:budget_envelope, budget: budget, name: "rent", starting_balance: 1234.5)
      bills = create(:budget_envelope, budget: budget, name: "Bills", starting_balance: 40)
      create(:budget_envelope, name: "Someone else's", starting_balance: 5)

      get month_path("2026-09")

      assert_select "thead th", text: "Envelope"
      assert_select "thead th", text: "Carried over"
      assert_select "thead th", text: "Available"
      assert_select "tbody tr", count: 2
      assert_select "tbody tr:nth-child(1) td:nth-child(1) a[href='#{month_envelope_path("2026-09", bills)}']", text: "Bills"
      assert_select "tbody tr:nth-child(1) td:nth-child(2)", text: "$40.00"
      assert_select "tbody tr:nth-child(1) td:nth-child(3)", text: "$40.00"
      assert_select "tbody tr:nth-child(2) td:nth-child(1) a[href='#{month_envelope_path("2026-09", rent)}']", text: "rent"
      assert_select "tbody tr:nth-child(2) td:nth-child(3)", text: "$1,234.50"
      expect(response.body).not_to include("Someone else")
    end

    it "show their Starting balance as Available in every month, and say Overspent when it's negative" do
      create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30)
      create(:budget_envelope, budget: budget, name: "Fuel", starting_balance: 0)

      [ "2026-09", "2024-01", "2031-12" ].each do |month|
        get month_path(month)

        assert_select "tbody tr:nth-child(1) td:nth-child(3)", text: /\A-\$30\.00\s+Overspent\z/
        assert_select "tbody tr:nth-child(1) td:nth-child(3) .text-error", text: "-$30.00"
        assert_select "tbody tr:nth-child(2) td:nth-child(3)", text: "$0.00"
        assert_select ".badge", text: "Overspent", count: 1
      end
    end

    it "right-align their amounts, and drop Carried over on a phone" do
      create(:budget_envelope, budget: budget)

      get month_path("2026-09")

      assert_select "thead th[scope=col].text-right", text: "Available"
      assert_select "thead th[class~='hidden'][class~='sm:table-cell']", text: "Carried over"
      assert_select "tbody td.text-right.tabular-nums", count: 2
      assert_select "tbody td[class~='hidden'][class~='sm:table-cell']", count: 1
    end

    it "are replaced by an invitation to create one when there are none" do
      get month_path("2026-09")

      assert_select "table", count: 0
      assert_select "main p", text: "You don't have any envelopes yet."
      assert_select ".border-dashed a[href='#{new_envelope_path(month: "2026-09", from: "month")}']", text: "New envelope"
    end
  end

  describe "the actions" do
    it "are New deposit, the main one, and New envelope, each remembering the month and page they were opened from" do
      get month_path("2026-09")

      assert_select "a.btn.btn-primary[href='#{new_deposit_path(month: "2026-09", from: "month")}']", text: "New deposit"
      assert_select "a.btn[href='#{new_envelope_path(month: "2026-09", from: "month")}']", text: "New envelope"
    end
  end

  describe "the month links" do
    before { travel_to Time.utc(2026, 9, 15, 16) }

    it "go to the months either side, and stay on the month view" do
      get month_path("2026-09")

      assert_select "nav[aria-label=Months] a[href='#{month_path("2026-08")}']", text: "August 2026"
      assert_select "nav[aria-label=Months] a[href='#{month_path("2026-10")}']", text: "October 2026"
    end

    it "offer This month only when viewing another month" do
      get month_path("2026-09")
      assert_select "a", text: "This month", count: 0

      get month_path("2027-03")
      assert_select "a[href='#{month_path("2026-09")}']", text: "This month"
    end

    it "work in both directions, however far from today" do
      get month_path("1990-01")
      assert_select "a[href='#{month_path("1989-12")}']", text: "December 1989"

      get month_path("2100-12")
      assert_select "a[href='#{month_path("2101-01")}']", text: "January 2101"
    end
  end
end
