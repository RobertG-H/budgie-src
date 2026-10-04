require "rails_helper"

RSpec.describe "The Bank transactions page", type: :request do
  include FilingHistory

  let(:budget) { create(:budget, currency: "CAD") }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:visa) { create(:budget_account, budget: budget, name: "Visa") }
  let(:account) { chequing }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

  before do
    travel_to Time.utc(2026, 10, 14, 16)
    sign_in_as budget.user
  end

  def rows
    css_select("main ul.list li").map { |row| row.text.squish }
  end

  def row_for(description)
    css_select("main ul.list li").find { |row| row.text.include?(description) } or raise "no row for #{description}"
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # A bank transaction of Chequing (or `account`) in a state, which is its description's own word: "unfiled one", "filed one".
  def make(state, description, date: Date.new(2026, 10, 3), account: chequing, amount: -20)
    traits = { unfiled: [], filed: [ :filed ], ignored: [ :ignored ] }.fetch(state)
    create(:budget_bank_transaction, *traits, account: account, date: date, description: description, amount: amount).reload
  end

  describe "GET /bank_transactions" do
    it "requires sign-in" do
      delete session_path

      get bank_transactions_path

      expect(response).to redirect_to(sign_in_path)
    end

    it "is a page for a budget, with a title and a way to it from every other page" do
      get bank_transactions_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Bank transactions · Budgie"
      assert_select "h1", text: "Bank transactions"
      assert_select "nav[aria-label=Sections] a[href='#{bank_transactions_path}'][aria-current=page]", text: "Bank transactions"
    end

    describe "All" do
      it "lists every unfiled bank transaction whatever its date, with the filed and ignored ones in the range, across the Accounts, newest first" do
        make(:unfiled, "Old unfiled", date: Date.new(2024, 3, 1))
        make(:unfiled, "New unfiled", date: Date.new(2026, 10, 9), account: visa, amount: -100)
        make(:filed, "In range filed", date: Date.new(2026, 10, 7), amount: -82.45)
        make(:ignored, "In range ignored", date: Date.new(2026, 10, 5), amount: 2800)
        make(:filed, "Before range filed", date: Date.new(2026, 9, 30))
        make(:ignored, "After range ignored", date: Date.new(2026, 11, 1))

        get bank_transactions_path

        expect(rows.map { |row| row[/(Old|New) unfiled|(In|Before|After) range (filed|ignored)/] }).to eq([ "New unfiled", "In range filed", "In range ignored", "Old unfiled" ])
        expect(rows.first).to eq("Oct 9, 2026 New unfiled Visa Unfiled -$100.00")
        assert_select "main ul.list li span.text-error", text: "-$100.00"
      end

      it "says the state of every row in a word, since what's offered isn't the only cue" do
        make(:unfiled, "An unfiled one")
        make(:filed, "A filed one")
        make(:ignored, "An ignored one")

        get bank_transactions_path

        expect(row_for("An unfiled one").css(".badge").map(&:text).map(&:squish)).to eq([ "Unfiled" ])
        expect(row_for("A filed one").css(".badge").map(&:text).map(&:squish)).to eq([ "Filed" ])
        expect(row_for("An ignored one").css(".badge").map(&:text).map(&:squish)).to eq([ "Ignored" ])
      end

      it "never lists another budget's bank transactions" do
        make(:unfiled, "Mine")
        create(:budget_bank_transaction, description: "Theirs unfiled", date: Date.new(2026, 10, 3))
        create(:budget_bank_transaction, :filed, description: "Theirs filed", date: Date.new(2026, 10, 3))
        create(:budget_bank_transaction, :ignored, description: "Theirs ignored", date: Date.new(2026, 10, 3))

        get bank_transactions_path

        expect(rows.size).to eq(1)
        expect(response.body).not_to include("Theirs")
      end

      it "has the dates as enabled fields, the presets and an Apply button, in a GET form" do
        get bank_transactions_path

        assert_select "form[method=get][action='#{bank_transactions_path}']" do
          assert_select "input[type=date][name='filter[date_from]'][value='2026-10-01']:not([disabled])"
          assert_select "input[type=date][name='filter[date_to]'][value='2026-10-31']:not([disabled])"
          assert_select "input[type=submit][value=Apply]"
        end
        expect(css_select("form a").map { |link| link.text.squish }).to eq([ "This month", "Last month", "Last 3 months" ])
        expect(css_select("a[aria-current=true]").map { |link| link.text.squish }).to eq([ "This month" ])
        assert_select "#filter_date_range_hint", count: 0
      end

      it "has presets that keep the state and the Account" do
        get bank_transactions_path(filter: { state: "filed", account: visa.id.to_s })

        last_month = css_select("form a").find { |link| link.text.squish == "Last month" }
        expect(last_month["href"]).to eq(bank_transactions_path(filter: { date_from: "2026-09-01", date_to: "2026-09-30", state: "filed", account: visa.id.to_s }))
      end

      it "uses the range it's given" do
        make(:filed, "In September", date: Date.new(2026, 9, 12))
        make(:filed, "In October", date: Date.new(2026, 10, 12))

        get bank_transactions_path(filter: { date_from: "2026-09-01", date_to: "2026-09-30" })

        expect(rows.size).to eq(1)
        expect(rows.first).to include("In September")
      end

      it "says a range that can't be used is, as an alert, and lists this month instead" do
        make(:filed, "In September", date: Date.new(2026, 9, 12))
        make(:filed, "In October", date: Date.new(2026, 10, 12))

        get bank_transactions_path(filter: { date_from: "2026-10-31", date_to: "2026-10-01" })

        assert_select "[role=alert]", text: /Choose a From and a To date, with From first. Showing this month instead./
        expect(rows.size).to eq(1)
        expect(rows.first).to include("In October")
      end
    end

    describe "Unfiled" do
      it "lists every unfiled bank transaction whatever its date, and nothing filed or ignored" do
        make(:unfiled, "Old", date: Date.new(2020, 1, 1))
        make(:unfiled, "Recent", date: Date.new(2026, 10, 1))
        make(:filed, "Filed", date: Date.new(2026, 10, 1))
        make(:ignored, "Ignored", date: Date.new(2026, 10, 1))

        get bank_transactions_path(filter: { state: "unfiled", date_from: "2026-01-01", date_to: "2026-01-31" })

        expect(rows.map { |row| row[/Old|Recent|Filed|Ignored/] }).to eq([ "Recent", "Old" ])
      end

      it "shows the dates disabled, with a hint that says why, and no presets, which have nothing to set" do
        get bank_transactions_path(filter: { state: "unfiled" })

        assert_select "input[type=date][name='filter[date_from]'][disabled]"
        assert_select "input[type=date][name='filter[date_to]'][disabled]"
        assert_select "p#filter_date_range_hint", text: "Unfiled bank transactions are listed whatever their date."
        assert_select "input[name='filter[date_from]'][aria-describedby~=filter_date_range_hint]"
        assert_select "form a", count: 0
        assert_select "input[type=submit][value=Apply]"
      end

      it "doesn't say a range is unusable, since it doesn't use one" do
        make(:unfiled, "One")

        get bank_transactions_path(filter: { state: "unfiled", date_from: "2026-10-31", date_to: "2026-10-01" })

        assert_select "[role=alert]", count: 0
        expect(rows.size).to eq(1)
      end

      it "leaves the state out of every row, since it's all the same, as the Unfiled list always did" do
        make(:unfiled, "One")

        get bank_transactions_path(filter: { state: "unfiled" })

        assert_select "main ul.list li .badge", count: 0
      end

      it "says when everything has been dealt with" do
        make(:filed, "Filed one")

        get bank_transactions_path(filter: { state: "unfiled" })

        assert_select "p", text: "Every bank transaction has been filed or ignored."
      end
    end

    describe "Filed and Ignored" do
      before do
        make(:filed, "Filed in range", date: Date.new(2026, 10, 3))
        make(:filed, "Filed before", date: Date.new(2026, 9, 3))
        make(:ignored, "Ignored in range", date: Date.new(2026, 10, 4))
        make(:ignored, "Ignored before", date: Date.new(2026, 9, 4))
        make(:unfiled, "Unfiled in range", date: Date.new(2026, 10, 5))
      end

      it "list the filed ones in the range, in Filed" do
        get bank_transactions_path(filter: { state: "filed" })

        expect(rows.map { |row| row[/Filed in range|Filed before|Ignored|Unfiled/] }).to eq([ "Filed in range" ])
        expect(row_for("Filed in range").css(".badge").map(&:text).map(&:squish)).to eq([ "Filed" ])
      end

      it "list the ignored ones in the range, in Ignored" do
        get bank_transactions_path(filter: { state: "ignored" })

        expect(rows.size).to eq(1)
        expect(rows.first).to include("Ignored in range")
      end

      it "use the range they're given" do
        get bank_transactions_path(filter: { state: "filed", date_from: "2026-09-01", date_to: "2026-09-30" })

        expect(rows.size).to eq(1)
        expect(rows.first).to include("Filed before")
      end
    end

    describe "the Account" do
      it "narrows to one Account, in every state" do
        make(:unfiled, "Visa unfiled", account: visa)
        make(:filed, "Visa filed", account: visa)
        make(:unfiled, "Chequing unfiled")
        make(:filed, "Chequing filed")

        get bank_transactions_path(filter: { account: visa.id.to_s })
        expect(rows.size).to eq(2)
        expect(response.body).not_to include("Chequing unfiled")

        get bank_transactions_path(filter: { account: visa.id.to_s, state: "unfiled" })
        expect(rows.size).to eq(1)
        expect(rows.first).to include("Visa unfiled")
      end

      it "is all Accounts for one that isn't the budget's, or that isn't an id" do
        other = create(:budget_account, name: "Someone else's")
        make(:unfiled, "Visa", account: visa)
        make(:unfiled, "Chequing")

        [ other.id.to_s, "abc", "", "99999999999999999999" ].each do |value|
          get bank_transactions_path(filter: { account: value })

          expect(rows.size).to eq(2)
          assert_select "select[name='filter[account]'] option[selected][value='']"
        end
      end

      it "has State and Account selects, with the filters in them" do
        get bank_transactions_path(filter: { state: "filed", account: visa.id.to_s })

        expect(css_select("select[name='filter[state]'] option").map { |option| option.text.squish }).to eq([ "All", "Unfiled", "Filed", "Ignored" ])
        expect(css_select("select[name='filter[account]'] option").map { |option| option.text.squish }).to eq([ "All accounts", "Chequing", "Visa" ])
        assert_select "select[name='filter[state]'] option[selected][value=filed]"
        assert_select "select[name='filter[account]'] option[selected][value='#{visa.id}']"
        assert_select "label[for=filter_state]", text: "State"
        assert_select "label[for=filter_account]", text: "Account"
      end

      it "is all states when the state isn't one of the four" do
        make(:unfiled, "One")
        make(:filed, "Two")

        get bank_transactions_path(filter: { state: "everything" })

        expect(rows.size).to eq(2)
        assert_select "select[name='filter[state]'] option[selected][value=all]"
      end
    end

    describe "what a row has" do
      it "shows a filed row's records, with Un-file, and says which Filing rule did it" do
        loblaws = make(:filed, "LOBLAWS #5", date: Date.new(2026, 10, 3), amount: -82.45)
        spend = loblaws.spend_links.sole.spend
        rule = create(:budget_filing_rule, budget: budget, envelope: spend.envelope, text: "loblaws")
        loblaws.update_columns(filing_rule_id: rule.id)

        get bank_transactions_path

        text = row_for("LOBLAWS #5").text.squish
        expect(text).to include("Spend from #{spend.envelope.name}", "Filing rule: loblaws → Spend from #{spend.envelope.name}")
        assert_select "main ul.list li form[action='#{bank_transaction_filing_path(loblaws)}'] button", text: "Un-file"
        assert_select "main ul.list li a.link[href='#{edit_filing_rule_path(rule)}']", text: "loblaws"
      end

      it "shows an ignored row with Un-ignore" do
        ignored = make(:ignored, "TRANSFER TO VISA")

        get bank_transactions_path

        assert_select "main ul.list li form[action='#{bank_transaction_ignore_path(ignored)}'] button", text: "Un-ignore"
      end

      it "flags a filed row whose records no longer add up, in words" do
        row = make(:filed, "Costco", amount: -50)
        row.spend_links.sole.spend.update!(amount: 40)

        get bank_transactions_path

        expect(row_for("Costco").text.squish).to include("Doesn't add up", "Its records add up to $40.00, not $50.00.")
        assert_select "main ul.list li span.badge.badge-warning", text: "Doesn't add up"
      end

      it "shows the Guess of an unfiled row, in All and in Unfiled, and nothing for a filed row" do
        filed("LOBLAWS #1234", groceries)
        unfiled("LOBLAWS #5678", date: Date.new(2026, 10, 6))

        [ {}, { state: "unfiled" } ].each do |filter|
          get bank_transactions_path(filter: filter)

          expect(row_for("LOBLAWS #5678").text.squish).to include("Guess: like LOBLAWS #1234 → Groceries")
        end

        get bank_transactions_path(filter: { state: "filed", date_from: "2026-09-01", date_to: "2026-09-30" })

        expect(rows.size).to eq(1)
        expect(rows.first).not_to include("Guess")
      end

      it "says which Account each row is in" do
        make(:unfiled, "Costco", account: visa)

        get bank_transactions_path

        expect(rows.first).to include("Visa")
      end
    end

    describe "opening a row, and coming back" do
      let(:filter) { { date_from: "2026-10-01", date_to: "2026-10-31", state: "unfiled", account: visa.id.to_s } }

      it "opens the filing form from an unfiled row, remembering the page and its filters" do
        row = make(:unfiled, "Costco", account: visa)

        get bank_transactions_path(filter: filter, page: nil)

        assert_select "main ul.list li a.list-row[href='#{new_bank_transaction_filing_path(row, from: "bank_transactions", filter: filter)}']"
      end

      it "remembers the page of the list when it isn't the first" do
        import = create(:budget_import, account: visa)
        55.times { |n| create(:budget_bank_transaction, account: visa, import: import, description: "Merchant #{n}", date: Date.new(2026, 10, 3)) }

        get bank_transactions_path(filter: filter, page: 2)

        hrefs = css_select("main ul.list li a.list-row").map { |link| link["href"] }
        expect(hrefs).to all(include("page=2"))
        expect(hrefs.size).to eq(5)
      end

      it "has Un-file and Un-ignore send the page and filters along, and goes back to them" do
        filed_row = make(:filed, "Filed", account: visa)
        ignored_row = make(:ignored, "Ignored", account: visa)
        all_filter = { date_from: "2026-10-01", date_to: "2026-10-31", account: visa.id.to_s }

        get bank_transactions_path(filter: all_filter, page: nil)

        assert_select "form[action='#{bank_transaction_filing_path(filed_row)}'] input[name=from][value=bank_transactions]"
        assert_select "form[action='#{bank_transaction_filing_path(filed_row)}'] input[name='filter[account]'][value='#{visa.id}']"

        delete bank_transaction_filing_path(filed_row), params: { from: "bank_transactions", filter: all_filter }
        expect(response).to redirect_to(bank_transactions_path(filter: all_filter))
        expect(filed_row.reload).to be_unfiled

        delete bank_transaction_ignore_path(ignored_row), params: { from: "bank_transactions", filter: all_filter, page: "2" }
        expect(response).to redirect_to(bank_transactions_path(filter: all_filter, page: 2))
        expect(ignored_row.reload).to be_unfiled
      end

      it "doesn't take a filter that isn't one back to anywhere but the page it understands" do
        row = make(:filed, "Filed")

        delete bank_transaction_filing_path(row), params: { from: "bank_transactions", filter: { state: "//evil.example", account: "javascript:alert(1)" }, page: "//evil" }

        expect(response).to redirect_to(bank_transactions_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" }))
        expect(response.location).not_to include("evil")
      end
    end

    describe "File N as guessed" do
      before do
        filed("LOBLAWS #1234", groceries)
        filed("COSTCO #12", household, account: visa)
        unfiled("LOBLAWS #5678", date: Date.new(2026, 10, 4))
        unfiled("COSTCO #99", date: Date.new(2026, 10, 3), account: visa)
        unfiled("SHELL OIL #55", date: Date.new(2026, 10, 2))
      end

      it "is only there under Unfiled, N being the rows on the page that have a Guess" do
        get bank_transactions_path(filter: { state: "unfiled" })
        assert_select "main a.btn[href='#{new_guessed_filing_path}']", text: "File 2 as guessed"

        [ {}, { state: "filed", date_from: "2026-09-01", date_to: "2026-09-30" }, { state: "ignored" } ].each do |filter|
          get bank_transactions_path(filter: filter)

          assert_select "main a", text: /as guessed/, count: 0
        end
      end

      it "reviews the Account's rows when one is chosen, and only that Account's" do
        get bank_transactions_path(filter: { state: "unfiled", account: visa.id.to_s })

        assert_select "main a.btn[href='#{new_guessed_filing_path(filter: { account: visa.id.to_s })}']", text: "File 1 as guessed"
      end

      it "reviews the page it's on" do
        import = create(:budget_import, account: chequing)
        55.times { |n| create(:budget_bank_transaction, account: chequing, import: import, description: "LOBLAWS ##{n + 100}", date: Date.new(2026, 9, 1) + (n % 28)) }

        get bank_transactions_path(filter: { state: "unfiled" }, page: 2)

        assert_select "main a.btn[href='#{new_guessed_filing_path(page: 2)}']"
      end

      it "offers nothing when no row has a Guess" do
        Budget::BankTransaction.where(description: [ "LOBLAWS #5678", "COSTCO #99" ]).update_all(ignored_at: Time.current)

        get bank_transactions_path(filter: { state: "unfiled" })

        assert_select "main a", text: /as guessed/, count: 0
      end
    end

    describe "when there's nothing to show" do
      it "says nothing matches, with a link to reset the filters, in All and in Filed and Ignored" do
        [ {}, { state: "filed" }, { state: "ignored", account: visa.id.to_s } ].each do |filter|
          get bank_transactions_path(filter: filter)

          assert_select "p", text: "No bank transactions match."
          assert_select "a[href='#{bank_transactions_path}']", text: "Reset the filters"
        end
      end

      it "says so past the last page, with a link back to the first, keeping the filters" do
        make(:unfiled, "One")

        get bank_transactions_path(filter: { state: "unfiled" }, page: 3)

        expect(response).to have_http_status(:ok)
        assert_select "p", text: "There are no more bank transactions."
        assert_select "a[href='#{bank_transactions_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", state: "unfiled" })}']", text: "Back to the first page"
      end

      it "treats a page that isn't a number as the first" do
        make(:unfiled, "One")

        get bank_transactions_path(page: "oops")

        expect(rows.size).to eq(1)
      end
    end

    describe "paging" do
      before do
        import = create(:budget_import, account: chequing)
        70.times { |n| create(:budget_bank_transaction, account: chequing, import: import, description: "Merchant #{n + 1}", date: Date.new(2026, 10, 31) - (n % 30)) }
      end

      it "shows 50 a page, newest first, with an Older link that keeps the filters, and the rest after it" do
        get bank_transactions_path(filter: { state: "unfiled", account: chequing.id.to_s })

        expect(rows.size).to eq(50)
        older = css_select("nav[aria-label=Pages] a[rel=next]").first["href"]
        expect(older).to eq(bank_transactions_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", state: "unfiled", account: chequing.id.to_s }, page: 2))

        get older

        expect(rows.size).to eq(20)
        assert_select "nav[aria-label=Pages] a[rel=prev]", text: "Newer"
      end
    end

    describe "the number of queries" do
      # `count` bank transactions of every state, in both Accounts, many of them with a Guess.
      def make_rows(count, prefix)
        import = { chequing => create(:budget_import, account: chequing), visa => create(:budget_import, account: visa) }
        count.times do |n|
          account = n.even? ? chequing : visa
          date = Date.new(2026, 10, 1) + (n % 28)
          description = n.odd? ? "LOBLAWS ##{prefix}#{n}" : "MERCHANT #{prefix} #{n}"
          row = create(:budget_bank_transaction, account: account, import: import[account], description: description, date: date, amount: -(n + 1))
          case n % 3
          when 0 then create(:budget_spend_link, bank_transaction: row, spend: create(:budget_spend, envelope: groceries, date: date, amount: n + 1))
          when 1 then row.update_columns(ignored_at: Time.current)
          end
        end
      end

      it "is the same for 5 bank transactions as for 50, in every state, however many are filed, with Guesses, and across Accounts" do
        filed("LOBLAWS #1234", groceries)
        create(:budget_filing_rule, budget: budget, envelope: household, text: "costco")
        make_rows(5, "a")

        counts = %w[ all unfiled filed ignored ].to_h do |state|
          get bank_transactions_path(filter: { state: state })
          [ state, count_queries { get bank_transactions_path(filter: { state: state }) } ]
        end

        make_rows(60, "b")
        file_in_bulk(100...600, household)

        %w[ all unfiled filed ignored ].each do |state|
          expect(count_queries { get bank_transactions_path(filter: { state: state }) }).to eq(counts.fetch(state)), "state #{state}"
        end
      end

      it "is the same on a full page as on a page of 5, with every kind of row on it" do
        make_rows(5, "a")
        get bank_transactions_path
        few = count_queries { get bank_transactions_path }

        make_rows(80, "b")
        expect(rows.size).to be <= 50
        many = count_queries { get bank_transactions_path }

        expect(many).to eq(few)
      end
    end

    it "creates and changes nothing, by being shown" do
      filed("LOBLAWS #1234", groceries)
      row = unfiled("LOBLAWS #5678")

      expect { get bank_transactions_path }
        .not_to change { [ Budget::Spend.count, Budget::SpendLink.count, Budget::FilingRule.count, row.reload.attributes ] }
    end

    it "is safe against a filter that isn't a hash, or that tries to be a URL" do
      [ "//evil.test", "javascript:alert(1)" ].each do |bad|
        get bank_transactions_path, params: { filter: bad }
        expect(response).to have_http_status(:ok)

        get bank_transactions_path, params: { filter: { state: bad, account: bad, date_from: bad, date_to: bad } }
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(bad)
      end

      get "/bank_transactions?filter[state][]=filed&filter[account][a]=1"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /unfiled" do
    it "goes permanently to the Unfiled state of the Bank transactions page" do
      get "/unfiled"

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to("/bank_transactions?filter%5Bstate%5D=unfiled")
    end

    it "keeps the page of the list" do
      get "/unfiled?page=3"

      expect(response).to redirect_to("/bank_transactions?filter%5Bstate%5D=unfiled&page=3")
    end

    it "keeps only a page that's a number, and goes nowhere but here" do
      [ "oops", "//evil.test", "3x", "99999999999", "" ].each do |page|
        get "/unfiled", params: { page: page }

        expect(response).to redirect_to("/bank_transactions?filter%5Bstate%5D=unfiled")
      end
    end

    it "lands on a page that works, and is signed in as before" do
      make(:unfiled, "Costco")

      get "/unfiled"
      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(rows.size).to eq(1)

      delete session_path
      get "/unfiled"
      follow_redirect!
      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "an Account's page" do
    it "lists its bank transactions as it always did, in every state, newest first, with no filters, and opens its forms back to itself" do
      unfiled = make(:unfiled, "Unfiled", date: Date.new(2020, 1, 1))
      make(:filed, "Filed", date: Date.new(2026, 10, 3))
      make(:ignored, "Ignored", date: Date.new(2026, 9, 3))
      make(:unfiled, "In Visa", account: visa)

      get account_path(chequing)

      expect(rows.size).to eq(3)
      assert_select "main ul.list li a.list-row[href='#{new_bank_transaction_filing_path(unfiled, from: "account")}']"
      assert_select "main ul.list form", count: 2 # Un-file and Un-ignore
      assert_select "main input[name='filter[state]']", count: 0
      assert_select "main select", count: 0
    end
  end
end
