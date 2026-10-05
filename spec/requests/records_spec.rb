require "rails_helper"

RSpec.describe "Records", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }

  before do
    travel_to Time.utc(2026, 10, 14, 16)
    sign_in_as budget.user
  end

  def deposit(attrs = {})
    create(:budget_deposit, { budget: budget, date: Date.new(2026, 10, 1) }.merge(attrs))
  end

  def spend(attrs = {})
    create(:budget_spend, { envelope: groceries, date: Date.new(2026, 10, 2) }.merge(attrs))
  end

  def refund(attrs = {})
    create(:budget_refund, { envelope: groceries, date: Date.new(2026, 10, 3) }.merge(attrs))
  end

  def reallocation(attrs = {})
    create(:budget_envelope_reallocation, { from_envelope: dining_out, to_envelope: groceries, date: Date.new(2026, 10, 4) }.merge(attrs))
  end

  def to_ready_to_assign(attrs = {})
    create(:budget_ready_to_assign_reallocation, { envelope: dining_out, date: Date.new(2026, 10, 5) }.merge(attrs))
  end

  # The rows of the list, each as its words squished: "Oct 2, 2026 Loblaws Spend from Groceries -$82.45".
  def rows
    css_select("ul.list > li").map { |row| row.text.squish }
  end

  def row_for(description)
    css_select("ul.list > li").find { |row| row.text.include?(description) } or raise "no row for #{description}"
  end

  describe "GET /records" do
    it "requires sign-in" do
      delete session_path

      get records_path

      expect(response).to redirect_to(sign_in_path)
    end

    it "is the page for a budget, with a title, and offers a way to every other page" do
      get records_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Records · Budgie"
      assert_select "h1", text: "Records"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", text: "Records"
    end

    it "is for a budget only: a user without one goes to set it up" do
      get records_path # signed in with a budget
      expect(response).to have_http_status(:ok)

      delete session_path
      sign_in_as create(:user)

      get records_path

      expect(response).to redirect_to(new_budget_path)
    end

    describe "the rows" do
      it "lists Deposits, Spends, Refunds and Reallocations of both kinds together, newest first, each saying what it is and where" do
        deposit(description: "Paycheck")
        spend(description: "Loblaws", amount: 82.45)
        refund(description: "Loblaws return", amount: 18.75)
        reallocation(description: "Covering the takeout", amount: 20)
        to_ready_to_assign(description: "Unspent fuel money", amount: 50)

        get records_path

        expect(rows).to eq([
          "Oct 5, 2026 Unspent fuel money Reallocation from Dining out to Ready to Assign $50.00",
          "Oct 4, 2026 Covering the takeout Reallocation from Dining out to Groceries $20.00",
          "Oct 3, 2026 Loblaws return Refund to Groceries $18.75",
          "Oct 2, 2026 Loblaws Spend from Groceries -$82.45",
          "Oct 1, 2026 Paycheck Deposit $100.00"
        ])
      end

      it "spells the year out, since a range can span years" do
        spend(description: "Last year", date: Date.new(2025, 12, 31))

        get records_path(filter: { date_from: "2025-01-01", date_to: "2026-12-31" })

        expect(rows.first).to start_with("Dec 31, 2025 Last year")
      end

      it "shows a Spend as negative and red, and a Refund, a Deposit and either Reallocation as positive, with no sign on a Reallocation" do
        spend(amount: 30)
        refund(amount: 10)
        deposit(amount: 3000)
        reallocation(amount: 20)
        to_ready_to_assign(amount: 5)

        get records_path

        assert_select "ul.list .text-error", count: 1
        assert_select "ul.list .text-error", text: "-$30.00"
        expect(css_select("ul.list li .text-right").map { |amount| amount.text.squish }).to match_array([ "-$30.00", "$10.00", "$3,000.00", "$20.00", "$5.00" ])
      end

      it "says a Deposit counts toward the month after only when it does" do
        deposit(description: "Paycheck", date: Date.new(2026, 10, 30), month: Date.new(2026, 11, 1))
        deposit(description: "Interest", date: Date.new(2026, 10, 31))

        get records_path

        expect(row_for("Paycheck").text.squish).to include("Deposit Counts toward November 2026")
        expect(row_for("Interest").text.squish).not_to include("Counts toward")
      end

      it "shows notes the way the other lists do" do
        spend(description: "Loblaws", notes: "For the party")

        get records_path

        expect(row_for("Loblaws").text.squish).to include("For the party")
        assert_select "ul.list span.whitespace-pre-line", text: "For the party"
      end

      it "includes a record in an archived envelope, with the envelope's name followed by the Archived badge" do
        closed = create(:budget_envelope, budget: budget, name: "Closed")
        spend(description: "Last order", envelope: closed)
        closed.update_columns(archived_at: Time.current)

        get records_path

        expect(row_for("Last order").text.squish).to include("Spend from Closed Archived")
        assert_select "ul.list .badge", text: "Archived", count: 1
      end

      it "names both envelopes of a Reallocation, each with its badge when it's archived" do
        closed = create(:budget_envelope, budget: budget, name: "Closed")
        reallocation(description: "Moving it", from_envelope: closed)
        closed.update_columns(archived_at: Time.current)

        get records_path

        expect(row_for("Moving it").text.squish).to include("Reallocation from Closed Archived to Groceries")
      end

      it "never lists another budget's records" do
        other = create(:budget)
        other_envelope = create(:budget_envelope, budget: other, name: "Theirs")
        create(:budget_deposit, budget: other, description: "Theirs deposit", date: Date.new(2026, 10, 2))
        create(:budget_spend, envelope: other_envelope, description: "Theirs spend", date: Date.new(2026, 10, 2))
        create(:budget_refund, envelope: other_envelope, description: "Theirs refund", date: Date.new(2026, 10, 2))
        create(:budget_envelope_reallocation, from_envelope: other_envelope, description: "Theirs move", date: Date.new(2026, 10, 2))
        create(:budget_ready_to_assign_reallocation, envelope: other_envelope, description: "Theirs back", date: Date.new(2026, 10, 2))
        spend(description: "Mine")

        get records_path

        expect(rows.size).to eq(1)
        expect(response.body).not_to include("Theirs")
      end

      it "opens each record's edit page from its row, remembering where it came from" do
        paycheck = deposit
        loblaws = spend
        returned = refund
        covering = reallocation
        unspent = to_ready_to_assign
        filter = { date_from: "2026-10-01", date_to: "2026-10-31" }

        get records_path

        hrefs = css_select("ul.list > li a").map { |link| link["href"] }
        expect(hrefs).to match_array([
          edit_deposit_path(paycheck, from: "records", filter: filter),
          edit_spend_path(loblaws, from: "records", filter: filter),
          edit_refund_path(returned, from: "records", filter: filter),
          edit_envelope_reallocation_path(covering, from: "records", filter: filter),
          edit_ready_to_assign_reallocation_path(unspent, from: "records", filter: filter)
        ])
      end

      it "has the whole row as the link" do
        spend

        get records_path

        assert_select "ul.list > li > a.list-row", count: 1
      end
    end

    describe "the date range" do
      it "is the current month, by Eastern time, when it's given none" do
        travel_to Time.utc(2026, 10, 1, 0, 30)
        spend(description: "In September", date: Date.new(2026, 9, 30))
        spend(description: "In October", date: Date.new(2026, 10, 1))

        get records_path

        expect(rows.size).to eq(1)
        expect(rows.first).to include("In September")
        assert_select "input[name='filter[date_from]'][value='2026-09-01']"
        assert_select "input[name='filter[date_to]'][value='2026-09-30']"
      end

      it "is the dates it's given, from the first to the last day, inclusive" do
        spend(description: "Before", date: Date.new(2026, 8, 31))
        spend(description: "From", date: Date.new(2026, 9, 1))
        spend(description: "To", date: Date.new(2026, 9, 30))
        spend(description: "After", date: Date.new(2026, 10, 1))

        get records_path(filter: { date_from: "2026-09-01", date_to: "2026-09-30" })

        expect(rows.map { |row| row[/\b(From|To|Before|After)\b/] }).to eq(%w[ To From ])
      end

      it "finds a Deposit by its date, and not by the month it counts toward" do
        deposit(description: "Paycheck", date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))

        get records_path(filter: { date_from: "2026-09-01", date_to: "2026-09-30" })
        expect(rows.size).to eq(1)

        get records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" })
        expect(rows).to be_empty
      end

      it "has From and To as labelled date fields, and an Apply button, in a GET form" do
        get records_path

        assert_select "form[method=get][action='#{records_path}']" do
          assert_select "label[for=filter_date_from]", text: "From"
          assert_select "label[for=filter_date_to]", text: "To"
          assert_select "input[type=date][name='filter[date_from]'][value='2026-10-01']"
          assert_select "input[type=date][name='filter[date_to]'][value='2026-10-31']"
          assert_select "input[type=submit][value=Apply]"
        end
        assert_select "input[name=commit]", count: 0
      end

      it "has presets as links, the current one marked, keeping the other filters" do
        get records_path(filter: { kind: "spend", envelope: groceries.id.to_s })

        expect(css_select("a[aria-current=true]").map { |link| link.text.squish }).to eq([ "This month" ])
        this_month = css_select("form a").find { |link| link.text.squish == "This month" }
        last_month = css_select("form a").find { |link| link.text.squish == "Last month" }
        last_3 = css_select("form a").find { |link| link.text.squish == "Last 3 months" }

        expect(last_month["href"]).to eq(records_path(filter: { date_from: "2026-09-01", date_to: "2026-09-30", kind: "spend", envelope: groceries.id.to_s }))
        expect(last_3["href"]).to eq(records_path(filter: { date_from: "2026-08-01", date_to: "2026-10-31", kind: "spend", envelope: groceries.id.to_s }))
        expect(this_month["href"]).to eq(records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", kind: "spend", envelope: groceries.id.to_s }))
      end

      it "marks Last month when that's the range, and no preset for another" do
        get records_path(filter: { date_from: "2026-09-01", date_to: "2026-09-30" })
        expect(css_select("a[aria-current=true]").map { |link| link.text.squish }).to eq([ "Last month" ])

        get records_path(filter: { date_from: "2026-09-02", date_to: "2026-09-30" })
        assert_select "a[aria-current=true]", count: 0
      end

      it "lists the last three months, the current one and the two before it, when asked" do
        spend(description: "August", date: Date.new(2026, 8, 1))
        spend(description: "July", date: Date.new(2026, 7, 31))

        get records_path(filter: { date_from: "2026-08-01", date_to: "2026-10-31" })

        expect(rows.size).to eq(1)
        expect(rows.first).to include("August")
      end
    end

    describe "a range that can't be used" do
      let(:alert) { "Choose a From and a To date, with From first. Showing this month instead." }

      [
        { date_from: "2026-09-01" },
        { date_to: "2026-09-30" },
        { date_from: "2026-09-30", date_to: "2026-09-01" },
        { date_from: "abc", date_to: "2026-09-30" },
        { date_from: "2026-13-01", date_to: "2026-13-02" }
      ].each do |filter|
        it "says so as an alert, and lists this month, for #{filter.inspect}" do
          spend(description: "This month's")
          spend(description: "Last month's", date: Date.new(2026, 9, 15))

          get records_path(filter: filter)

          expect(response).to have_http_status(:ok)
          assert_select "[role=alert]", text: /#{Regexp.escape(alert)}/
          expect(rows.size).to eq(1)
          expect(rows.first).to include("This month's")
          assert_select "input[name='filter[date_from]'][value='2026-10-01']"
          assert_select "input[name='filter[date_to]'][value='2026-10-31']"
        end
      end

      it "says nothing when both ends are blank, which is the default" do
        get records_path(filter: { date_from: "", date_to: "" })

        assert_select "[role=alert]", count: 0
      end

      it "keeps the Kind and the envelope when the dates are the trouble" do
        spend(description: "Loblaws")
        refund(description: "Return")

        get records_path(filter: { date_from: "oops", date_to: "2026-09-30", kind: "spend" })

        expect(rows.size).to eq(1)
        expect(rows.first).to include("Loblaws")
        assert_select "select[name='filter[kind]'] option[selected][value=spend]"
      end
    end

    describe "the Kind and envelope filters" do
      before do
        deposit(description: "Paycheck")
        spend(description: "Loblaws")
        spend(description: "Takeout", envelope: dining_out)
        refund(description: "Return")
        reallocation(description: "Covering")
        to_ready_to_assign(description: "Unspent")
      end

      def descriptions
        rows.map { |row| row[/\b(Paycheck|Loblaws|Takeout|Return|Covering|Unspent)\b/] }
      end

      it "has a Kind select with All, Deposit, Spend, Refund and Reallocation, and an Envelope select with every envelope" do
        closed = create(:budget_envelope, budget: budget, name: "Closed")
        closed.update_columns(archived_at: Time.current)

        get records_path

        expect(css_select("select[name='filter[kind]'] option").map { |option| option.text.squish }).to eq([ "All", "Deposit", "Spend", "Refund", "Reallocation" ])
        expect(css_select("select[name='filter[envelope]'] option").map { |option| option.text.squish }).to eq([ "All envelopes", "Closed (archived)", "Dining out", "Groceries" ])
        assert_select "label[for=filter_kind]", text: "Kind"
        assert_select "label[for=filter_envelope]", text: "Envelope"
      end

      it "says choosing an envelope leaves out Deposits, in a hint the select is described by" do
        get records_path

        assert_select "select[name='filter[envelope]'][aria-describedby=filter_envelope_hint]"
        assert_select "p#filter_envelope_hint", text: "Deposits aren't in an envelope, so choosing one leaves them out."
      end

      it "narrows to one kind" do
        get records_path(filter: { kind: "spend" })
        expect(descriptions).to eq(%w[ Takeout Loblaws ])
        assert_select "select[name='filter[kind]'] option[selected][value=spend]"

        get records_path(filter: { kind: "deposit" })
        expect(descriptions).to eq(%w[ Paycheck ])

        get records_path(filter: { kind: "refund" })
        expect(descriptions).to eq(%w[ Return ])
      end

      it "has Reallocations of both tables for the Reallocation kind" do
        get records_path(filter: { kind: "reallocation" })

        expect(descriptions).to eq(%w[ Unspent Covering ])
      end

      it "narrows to an envelope, leaving out Deposits, and finds a Reallocation by either of its envelopes" do
        get records_path(filter: { envelope: groceries.id.to_s })
        expect(descriptions).to eq(%w[ Covering Return Loblaws ])
        assert_select "select[name='filter[envelope]'] option[selected][value='#{groceries.id}']"

        get records_path(filter: { envelope: dining_out.id.to_s })
        expect(descriptions).to eq(%w[ Unspent Covering Takeout ])
      end

      it "is all envelopes for an id that isn't one of this budget's" do
        other = create(:budget_envelope)

        get records_path(filter: { envelope: other.id.to_s })

        expect(rows.size).to eq(6)
        assert_select "select[name='filter[envelope]'] option[selected][value='']"
      end

      it "keeps the filters in the form when a page is shown" do
        get records_path(filter: { kind: "spend", envelope: groceries.id.to_s, date_from: "2026-09-01", date_to: "2026-10-31" })

        assert_select "input[name='filter[date_from]'][value='2026-09-01']"
        assert_select "input[name='filter[date_to]'][value='2026-10-31']"
        assert_select "select[name='filter[kind]'] option[selected][value=spend]"
        assert_select "select[name='filter[envelope]'] option[selected][value='#{groceries.id}']"
      end
    end

    describe "the totals" do
      it "are Money in and Money out for the range, and say Reallocations aren't counted" do
        deposit(amount: 3000)
        refund(amount: 12.5)
        spend(amount: 82.45)
        spend(amount: 17.55)
        reallocation(amount: 40)
        to_ready_to_assign(amount: 25)

        get records_path

        expect(css_select("dl > div").map { |figure| figure.text.squish }).to eq([ "Money in $3,012.50", "Money out $100.00" ])
        assert_select "p", text: "Reallocations only change which envelope money is in, so they aren't counted."
      end

      it "are for the whole range, not the page" do
        60.times { |i| spend(amount: 1, date: Date.new(2026, 10, 1) + (i % 28)) }

        get records_path

        expect(rows.size).to eq(50)
        expect(css_select("dl > div").map { |figure| figure.text.squish }).to include("Money out $60.00")
      end

      it "follow the filters, and show no money in for a Kind that has none" do
        refund(amount: 12)
        spend(amount: 20)

        get records_path(filter: { kind: "spend" })

        expect(css_select("dl > div").map { |figure| figure.text.squish }).to eq([ "Money in $0.00", "Money out $20.00" ])
      end

      it "are left out for Reallocations alone, which have no money in or out" do
        reallocation

        get records_path(filter: { kind: "reallocation" })

        assert_select "dl", count: 0
        expect(response.body).not_to include("aren't counted")
      end

      it "are in the budget's currency" do
        budget.update!(currency: "GBP")
        spend(amount: 5)

        get records_path

        expect(css_select("dl > div").map { |figure| figure.text.squish }).to eq([ "Money in £0.00", "Money out £5.00" ])
      end
    end

    describe "when there's nothing to show" do
      it "says there are no records in the range, with the dates spelled out, and no way back when it's the default" do
        get records_path

        assert_select "p", text: "No records from Oct 1, 2026 to Oct 31, 2026."
        assert_select "a", text: "Show this month", count: 0
      end

      it "offers Show this month, keeping the other filters, when the range isn't the default" do
        get records_path(filter: { date_from: "2026-01-01", date_to: "2026-01-31", kind: "spend" })

        assert_select "p", text: "No records from Jan 1, 2026 to Jan 31, 2026."
        assert_select "a[href='#{records_path(filter: { kind: "spend" })}']", text: "Show this month"
      end

      it "says so past the last page, with a link back to the first, keeping the filters" do
        spend

        get records_path(filter: { kind: "spend" }, page: 2)

        expect(response).to have_http_status(:ok)
        assert_select "p", text: "There are no more records."
        assert_select "a[href='#{records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", kind: "spend" })}']", text: "Back to the first page"
      end

      it "treats a page that isn't a number as the first" do
        spend

        get records_path(page: "oops")

        expect(rows.size).to eq(1)
      end
    end

    describe "paging" do
      before { 60.times { |i| spend(description: "Spend #{i}", amount: 1, date: Date.new(2026, 10, 1) + (i % 28)) } }

      it "shows 50 a page, newest first, with an Older link that keeps the filters" do
        get records_path(filter: { kind: "spend", date_from: "2026-10-01", date_to: "2026-10-31" })

        expect(rows.size).to eq(50)
        assert_select "nav[aria-label=Pages] a[rel=next]", text: "Older"
        older = css_select("nav[aria-label=Pages] a[rel=next]").first["href"]
        expect(older).to eq(records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", kind: "spend" }, page: 2))
      end

      it "shows the rest on the second page, with a Newer link back to the first, which has no page param" do
        get records_path(filter: { kind: "spend", date_from: "2026-10-01", date_to: "2026-10-31" }, page: 2)

        expect(rows.size).to eq(10)
        newer = css_select("nav[aria-label=Pages] a[rel=prev]").first["href"]
        expect(newer).to eq(records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", kind: "spend" }))
      end

      it "opens a record from the second page with that page remembered" do
        get records_path(page: 2)

        hrefs = css_select("ul.list > li a").map { |link| link["href"] }
        expect(hrefs).to all(include("page=2"))
      end
    end

    describe "the number of queries" do
      def make_records(count)
        count.times do |i|
          date = Date.new(2026, 10, 1) + (i % 28)
          deposit(date: date)
          spend(date: date)
          refund(date: date)
          reallocation(date: date)
          to_ready_to_assign(date: date)
        end
      end

      it "is the same for 5 records as for 50 of each kind" do
        make_records(1)
        get records_path
        small = count_queries { get records_path }

        make_records(49)
        large = count_queries { get records_path }

        expect(large).to eq(small)
        expect(rows.size).to eq(50)
      end

      it "is the same on a filtered page" do
        make_records(1)
        filter = { kind: "reallocation", envelope: dining_out.id.to_s }
        small = count_queries { get records_path(filter: filter) }

        make_records(49)
        large = count_queries { get records_path(filter: filter) }

        expect(large).to eq(small)
      end
    end

    it "is safe against a filter that isn't a hash, or that tries to be a URL" do
      [ "//evil.test", "javascript:alert(1)" ].each do |bad|
        get records_path, params: { filter: bad }
        expect(response).to have_http_status(:ok)

        get records_path, params: { filter: { kind: bad, envelope: bad, date_from: bad, date_to: bad } }
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(bad)
      end

      get "/records?filter[kind][]=spend&filter[envelope][a]=1"
      expect(response).to have_http_status(:ok)
    end
  end

  # A form opened from a row of the list carries the list's filter and page, and saving, deleting or cancelling goes back to the
  # same filtered page. Each of the five kinds of record has its own controller.
  describe "opening a record and coming back" do
    let(:filter) { { date_from: "2026-09-01", date_to: "2026-10-31", kind: "spend", envelope: groceries.id.to_s } }
    let(:back) { records_path(filter: filter, page: 2) }
    let(:origin) { { from: "records", filter: filter, page: "2" } }
    let(:envelope_hidden) { css_select("input[type=hidden][name^='filter[']").to_h { |field| [ field["name"], field["value"] ] } }

    # Every kind: how its edit page is opened, how it's saved, and how it's deleted.
    {
      "a Deposit" => [ :paycheck, :edit_deposit_path, :deposit_path, { deposit: { description: "Edited" } } ],
      "a Spend" => [ :loblaws, :edit_spend_path, :spend_path, { spend: { description: "Edited" } } ],
      "a Refund" => [ :returned, :edit_refund_path, :refund_path, { refund: { description: "Edited" } } ],
      "a Reallocation between envelopes" => [ :covering, :edit_envelope_reallocation_path, :envelope_reallocation_path, { reallocation: { description: "Edited" } } ],
      "a Reallocation to Ready to Assign" => [ :unspent, :edit_ready_to_assign_reallocation_path, :ready_to_assign_reallocation_path, { reallocation: { description: "Edited" } } ]
    }.each do |name, (record_name, edit_helper, record_helper, update_params)|
      describe name do
        let!(:records) do
          { paycheck: deposit, loblaws: spend, returned: refund, covering: reallocation, unspent: to_ready_to_assign }
        end
        let(:record) { records.fetch(record_name) }
        let(:edit_path) { public_send(edit_helper, record) }
        let(:record_path) { public_send(record_helper, record) }

        it "has the page and filter it was opened from in its form, and a Cancel that goes back to them" do
          get edit_path, params: origin

          expect(response).to have_http_status(:ok)
          assert_select "form input[type=hidden][name=from][value=records]"
          assert_select "form input[type=hidden][name=page][value='2']"
          expect(envelope_hidden).to eq(filter.transform_keys { |key| "filter[#{key}]" }.transform_values(&:to_s))
          assert_select "a.btn[href='#{back}']", text: "Cancel"
        end

        it "goes back to the same filtered page when it's saved" do
          patch record_path, params: update_params.merge(origin)

          expect(response).to redirect_to(back)
        end

        it "goes back to the same filtered page when it's deleted" do
          delete record_path, params: origin

          expect(response).to redirect_to(back)
          expect(response).to have_http_status(:see_other)
        end

        it "has a Delete button that carries the page and filter along" do
          get edit_path, params: origin

          assert_select "form[action='#{record_path}'] input[type=hidden][name=from][value=records]"
          assert_select "form[action='#{record_path}'] input[type=hidden][name=page][value='2']"
          assert_select "form[action='#{record_path}'] input[type=hidden][name='filter[kind]'][value=spend]"
        end

        it "doesn't go to the Records page when the page it names isn't one" do
          patch record_path, params: update_params.merge(from: "http://evil.test", filter: filter, page: "2")

          expect(response.location).not_to include("evil.test")
          expect(response.location).not_to include("/records")
        end
      end
    end

    it "goes back to the page the record was moved out of the range on, which then doesn't list it" do
      loblaws = spend(description: "Loblaws", date: Date.new(2026, 10, 2))

      patch spend_path(loblaws), params: { spend: { date: "2025-01-01" } }.merge(origin)
      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Loblaws")
    end

    it "goes back to page 1 without a page param when it was opened from the first" do
      loblaws = spend

      delete spend_path(loblaws), params: { from: "records", filter: filter }

      expect(response).to redirect_to(records_path(filter: filter))
    end

    it "rebuilds the filter through the Records page's parser, so only what it understood goes back, and never a URL" do
      loblaws = spend

      delete spend_path(loblaws), params: { from: "records", filter: { date_from: "http://evil.test", date_to: "//evil.test", kind: "//evil.test", envelope: "//evil.test" }, page: "//evil.test" }

      expect(response).to redirect_to(records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" }))
      expect(response.location).not_to include("evil")
    end

    it "drops a filter that isn't a hash" do
      loblaws = spend

      delete spend_path(loblaws), params: { from: "records", filter: "//evil.test" }

      expect(response).to redirect_to(records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" }))
    end

    it "comes back with the form as it was entered when a save is refused, still carrying the filter" do
      loblaws = spend

      patch spend_path(loblaws), params: { spend: { description: "" } }.merge(origin)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "form input[type=hidden][name=from][value=records]"
      assert_select "form input[type=hidden][name='filter[kind]'][value=spend]"
      assert_select "a.btn[href='#{back}']", text: "Cancel"
    end

    it "is a 404 for another user's record, as it was before" do
      other = create(:budget_envelope)
      foreign_spend = create(:budget_spend, envelope: other)
      foreign_deposit = create(:budget_deposit)

      get edit_spend_path(foreign_spend), params: origin
      expect(response).to have_http_status(:not_found)

      get edit_deposit_path(foreign_deposit), params: origin
      expect(response).to have_http_status(:not_found)
    end
  end
end
