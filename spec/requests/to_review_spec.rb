require "rails_helper"

# What a Filing rule filed or ignored is to review until a person has looked at it (ADR 0017): the To review state of the Bank transactions page, the badge
# and Mark reviewed on a row, and what un-filing or un-ignoring from it does.
RSpec.describe "Bank transactions to review", type: :request do
  include FilingHistory

  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:visa) { create(:budget_account, budget: budget, name: "Visa") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

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

  # A bank transaction that a Filing rule filed as a Spend from Groceries, or ignored, that nobody has looked at.
  def by_rule(description, *traits, account: self.account, amount: -20, date: Date.new(2026, 10, 3), rule: nil)
    bank_transaction = create(:budget_bank_transaction, *traits, account: account, description: description, amount: amount, date: date)
    rule ||= create(:budget_filing_rule, budget: budget, envelope: groceries, text: "#{description.downcase.gsub(/\d/, "")} rule")
    bank_transaction.update_columns(filing_rule_id: rule.id)
    bank_transaction.reload
  end

  describe "the To review state" do
    it "lists what rules filed and what they ignored that nobody has looked at, in any Account, whatever the date, and nothing else" do
      by_rule("Filed by a rule", :filed)
      by_rule("Ignored by a rule", :ignored, account: visa, date: Date.new(2024, 1, 1))
      by_rule("Reviewed already", :filed, :reviewed)
      create(:budget_bank_transaction, :filed, account: account, description: "Filed by a person")
      create(:budget_bank_transaction, :ignored, account: account, description: "Ignored by a person")
      create(:budget_bank_transaction, account: account, description: "Unfiled")

      get bank_transactions_path(filter: { state: "to_review" })

      expect(response).to have_http_status(:ok)
      expect(rows.map { |row| row[/Filed by a rule|Ignored by a rule|Reviewed already|by a person|Unfiled/] }).to eq([ "Filed by a rule", "Ignored by a rule" ])
    end

    it "says each row's state in words, what it was filed as and which Filing rule did it, with its link, and a To review badge" do
      loblaws = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      by_rule("LOBLAWS #1", :filed, rule: loblaws)
      by_rule("PAYMENT", :ignored, rule: create(:budget_filing_rule, :ignore, budget: budget, text: "payment"))

      get bank_transactions_path(filter: { state: "to_review" })

      filed = row_for("LOBLAWS #1")
      expect(filed.css(".badge").map { |badge| badge.text.squish }).to eq([ "Filed", "To review" ])
      expect(filed.text.squish).to include("Filing rule: loblaws → Spend from", "Un-file", "Mark reviewed")
      expect(filed.css("a").map { |link| link["href"] }).to include(edit_filing_rule_path(loblaws))
      expect(row_for("PAYMENT").css(".badge").map { |badge| badge.text.squish }).to eq([ "Ignored", "To review" ])
      expect(row_for("PAYMENT").text.squish).to include("Filing rule: payment → Ignore", "Un-ignore", "Mark reviewed")
    end

    it "says when there's nothing to review" do
      get bank_transactions_path(filter: { state: "to_review" })

      assert_select "p", text: /Nothing to review/
    end

    it "starts with any date, takes a range, and doesn't carry the current month over from the state it came from" do
      by_rule("Old one", :filed, date: Date.new(2024, 1, 1))
      by_rule("This month", :filed)

      get bank_transactions_path(filter: { state: "to_review" })
      expect(rows.size).to eq(2)
      assert_select "form a[aria-current=true]", text: "Any date"

      get bank_transactions_path(filter: { state: "to_review", date_from: "2026-10-01", date_to: "2026-10-31" })
      expect(rows.map { |row| row[/Old one|This month/] }).to eq([ "This month" ])

      get bank_transactions_path(filter: { state: "to_review", from_state: "filed", date_from: "2026-10-01", date_to: "2026-10-31" })
      expect(rows.size).to eq(2)
    end

    it "is narrowed to an Account" do
      by_rule("In Chequing", :filed)
      by_rule("In Visa", :filed, account: visa)

      get bank_transactions_path(filter: { state: "to_review", account: visa.id.to_s })

      expect(rows.map { |row| row[/In Chequing|In Visa/] }).to eq([ "In Visa" ])
    end

    it "refreshes in place, keeping the scroll position, so Mark reviewed doesn't send the person back to the top" do
      by_rule("Filed by a rule", :filed)

      get bank_transactions_path(filter: { state: "to_review" })

      assert_select "head meta[name=turbo-refresh-method][content=morph]"
      assert_select "head meta[name=turbo-refresh-scroll][content=preserve]"
      assert_select "div[data-controller=bulk-selection][data-action*='turbo:morph@document->bulk-selection#restore']"
    end

    it "is in the State select, after Unfiled" do
      get bank_transactions_path(filter: { state: "to_review" })

      expect(css_select("select[name='filter[state]'] option").map { |option| option.text.squish }).to eq([ "All", "Unfiled", "To review", "Filed", "Ignored" ])
      assert_select "select[name='filter[state]'] option[selected][value=to_review]"
    end

    it "never lists another budget's" do
      other = create(:budget_account, budget: create(:budget))
      create(:budget_bank_transaction, :filed, :by_rule, account: other, description: "Not mine")

      get bank_transactions_path(filter: { state: "to_review" })

      expect(rows).to be_empty
    end

    it "runs the same number of queries for 5 rows as for 50, however many rules there are" do
      few = create_list(:budget_bank_transaction, 5, :filed, :by_rule, account: account)
      get bank_transactions_path(filter: { state: "to_review" })
      expect(rows.size).to eq(5)
      small = count_queries { get bank_transactions_path(filter: { state: "to_review" }) }

      many = create_list(:budget_bank_transaction, 45, :filed, :by_rule, account: account) + create_list(:budget_bank_transaction, 3, :ignored, :by_rule, account: visa)
      get bank_transactions_path(filter: { state: "to_review" })
      expect(rows.size).to eq(50)
      large = count_queries { get bank_transactions_path(filter: { state: "to_review" }) }

      expect(large).to eq(small)
      expect(few.size + many.size).to eq(53)
    end
  end

  describe "the badge and Mark reviewed on a row, wherever the row is" do
    let!(:filed) { by_rule("Filed by a rule", :filed) }
    let!(:ignored) { by_rule("Ignored by a rule", :ignored) }
    let!(:by_person) { create(:budget_bank_transaction, :filed, account: account, description: "Filed by a person", date: Date.new(2026, 10, 3)) }

    it "is on rows in All, Filed and Ignored, and on the Account's page, and not on one a person filed" do
      [ bank_transactions_path, bank_transactions_path(filter: { state: "filed" }), bank_transactions_path(filter: { state: "ignored" }), account_path(account) ].each do |path|
        get path

        listed = css_select("main ul.list li").select { |row| row.text.include?("by a rule") }
        expect(listed).not_to be_empty
        expect(listed.map { |row| row.css(".badge").map { |badge| badge.text.squish }.include?("To review") }).to all(be(true))
        expect(listed.map { |row| row.text.include?("Mark reviewed") }).to all(be(true))
        expect(css_select("main ul.list li").select { |row| row.text.include?("by a person") }.map { |row| row.text.include?("To review") || row.text.include?("Mark reviewed") }).to all(be(false))
      end
    end

    it "sends the page and filter along, so Mark reviewed comes back to them" do
      get bank_transactions_path(filter: { state: "to_review" }, page: 1)

      assert_select "form[action='#{bank_transaction_review_path(filed)}'][method=post]" do
        assert_select "input[type=hidden][name=from][value=bank_transactions]"
        assert_select "input[type=hidden][name='filter[state]'][value=to_review]"
        assert_select "button", text: "Mark reviewed"
      end
    end

    it "marks it reviewed, and comes back to the page it was on, saying so" do
      filter = { state: "to_review" }

      post bank_transaction_review_path(ignored), params: { from: "bank_transactions", filter: filter, page: 2 }
      expect(response).to redirect_to(bank_transactions_path(filter: filter, page: 2))

      post bank_transaction_review_path(filed), params: { from: "bank_transactions", filter: filter }

      expect(filed.reload).not_to be_to_review
      expect(response).to redirect_to(bank_transactions_path(filter: filter))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Bank transaction marked reviewed.")
      follow_redirect!
      expect(rows).to be_empty
    end

    it "goes back to the Account's page from there, and to its Account without a way back" do
      post bank_transaction_review_path(filed), params: { from: "account" }
      expect(response).to redirect_to(account_path(account))

      post bank_transaction_review_path(ignored)
      expect(response).to redirect_to(account_path(account))
      expect(ignored.reload).not_to be_to_review
    end

    it "is refused for one that isn't to review, with where it was opened from and the reason" do
      post bank_transaction_review_path(by_person), params: { from: "account" }

      expect(response).to redirect_to(account_path(account))
      expect(flash[:alert]).to eq("This bank transaction isn't to review.")
    end

    it "is a 404 for another user's bank transaction, which stays to review" do
      theirs = create(:budget_bank_transaction, :filed, :by_rule, account: create(:budget_account, budget: create(:budget)))

      post bank_transaction_review_path(theirs)

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload).to be_to_review
    end

    it "requires sign-in" do
      delete session_path

      post bank_transaction_review_path(filed)

      expect(response).to redirect_to(sign_in_path)
      expect(filed.reload).to be_to_review
    end
  end

  describe "saving an edit to a record filed by a rule" do
    it "takes the bank transaction out of To review, from the page of the record's own edit form" do
      filed = by_rule("Filed by a rule", :filed)
      spend = filed.spend_links.sole.spend

      patch spend_path(spend), params: { spend: { description: "Filed by a rule", amount: "20.00", date: "2026-10-03", envelope_id: spend.envelope_id, notes: "Looked" } }

      expect(response).to have_http_status(:redirect)
      expect(filed.reload).not_to be_to_review
    end
  end

  describe "Un-file and Un-ignore from To review" do
    let!(:filed) { by_rule("Filed by a rule", :filed) }
    let!(:ignored) { by_rule("Ignored by a rule", :ignored) }
    let(:origin) { { from: "bank_transactions", filter: { state: "to_review" }, page: 2 } }

    it "takes Un-file straight to the filing form, with the same way back, since the only reason to do it there is that the rule got it wrong" do
      delete bank_transaction_filing_path(filed), params: origin

      expect(filed.reload).to be_unfiled
      expect(response).to redirect_to(new_bank_transaction_filing_path(filed, from: "bank_transactions", filter: { state: "to_review" }, page: 2))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction unfiled."
      assert_select "h1", text: "File bank transaction"
    end

    it "takes Un-ignore straight to the filing form too, so a wrongly ignored bank transaction is filed in two clicks" do
      delete bank_transaction_ignore_path(ignored), params: origin

      expect(ignored.reload).to be_unfiled
      expect(response).to redirect_to(new_bank_transaction_filing_path(ignored, from: "bank_transactions", filter: { state: "to_review" }, page: 2))
      follow_redirect!
      assert_select "h1", text: "File bank transaction"
      assert_select "input[type=hidden][name='filter[state]'][value=to_review]"
    end

    it "goes back to the list from every other state and page, as before" do
      delete bank_transaction_filing_path(filed), params: { from: "bank_transactions", filter: { state: "filed" } }
      expect(response).to redirect_to(bank_transactions_path(filter: { state: "filed", date_from: "2026-10-01", date_to: "2026-10-31" }))

      delete bank_transaction_ignore_path(ignored), params: { from: "account" }
      expect(response).to redirect_to(account_path(account))
    end

    it "goes back to the list when it isn't unfiled afterwards, such as one that went from Splitwise" do
      splitwise = create(:budget_account, :synced, budget: budget)
      gone = create(:budget_bank_transaction, :filed, :by_rule, :removed, account: splitwise)

      delete bank_transaction_filing_path(gone), params: origin

      expect(gone.reload).to be_removed
      expect(response).to redirect_to(bank_transactions_path(filter: { state: "to_review" }, page: 2))
    end
  end

  describe "File and next" do
    let!(:newest) { create(:budget_bank_transaction, account: account, description: "NEWEST", date: Date.new(2026, 10, 12)) }
    let!(:in_range) { create(:budget_bank_transaction, account: account, description: "IN RANGE", date: Date.new(2026, 10, 5)) }
    let!(:out_of_range) { create(:budget_bank_transaction, account: account, description: "OUT OF RANGE", date: Date.new(2026, 8, 5)) }
    let(:range) { { state: "unfiled", date_from: "2026-10-01", date_to: "2026-10-31" } }

    def file_and_next(bank_transaction, filter:)
      post bank_transaction_filing_path(bank_transaction), params: {
        from: "bank_transactions", filter: filter, next: "1",
        filing: { records: { "0" => { kind: "spend", envelope_id: groceries.id, description: bank_transaction.description, date: bank_transaction.date.iso8601, amount: bank_transaction.amount.abs.to_s, notes: "" } } }
      }
    end

    it "goes on to the next one in the range, and stops with the message at the end of it, and not on to one outside it" do
      file_and_next newest, filter: range
      expect(response).to redirect_to(new_bank_transaction_filing_path(in_range, from: "bank_transactions", filter: range))

      file_and_next in_range, filter: range

      expect(response).to redirect_to(bank_transactions_path(filter: range))
      expect(flash[:notice]).to eq("Bank transaction filed. No more unfiled bank transactions.")
      expect(out_of_range.reload).to be_unfiled
    end

    it "doesn't wrap to one outside the range from the oldest in it" do
      file_and_next in_range, filter: range
      expect(response).to redirect_to(new_bank_transaction_filing_path(newest, from: "bank_transactions", filter: range))
    end

    it "goes through every unfiled one, whatever its date, from Unfiled with any date, as it always did" do
      any_date = { state: "unfiled" }

      file_and_next in_range, filter: any_date

      expect(response).to redirect_to(new_bank_transaction_filing_path(out_of_range, from: "bank_transactions", filter: any_date))
    end

    it "offers the buttons only when there's a next one in the range" do
      get new_bank_transaction_filing_path(in_range, from: "bank_transactions", filter: range)
      assert_select "button[name=next]", text: "File and next"

      get new_bank_transaction_filing_path(out_of_range, from: "bank_transactions", filter: range)
      assert_select "button[name=next]", text: "File and next"

      out_of_range.update!(date: Date.new(2026, 10, 1))
      newest.update!(ignored_at: Time.current)
      in_range.update!(ignored_at: Time.current)
      get new_bank_transaction_filing_path(out_of_range, from: "bank_transactions", filter: range)
      assert_select "button[name=next]", count: 0
    end
  end

  describe "File N as guessed" do
    let!(:loblaws_history) { filed("LOBLAWS #1234", groceries, date: Date.new(2026, 1, 10)) }
    let!(:in_range) { unfiled("LOBLAWS #5678", date: Date.new(2026, 10, 4)) }
    let!(:out_of_range) { unfiled("LOBLAWS #9999", date: Date.new(2026, 8, 4)) }
    let(:range) { { state: "unfiled", date_from: "2026-10-01", date_to: "2026-10-31" } }

    it "counts the rows of the range, and carries the range as well as the Account, so its review shows the same rows" do
      get bank_transactions_path(filter: range.merge(account: account.id.to_s))

      assert_select "main a.btn[href='#{new_guessed_filing_path(filter: { account: account.id.to_s, date_from: "2026-10-01", date_to: "2026-10-31" })}']", text: "File 1 as guessed"

      get new_guessed_filing_path(filter: { account: account.id.to_s, date_from: "2026-10-01", date_to: "2026-10-31" })

      expect(rows.size).to eq(1)
      expect(rows.first).to include("LOBLAWS #5678")
      assert_select "input[type=hidden][name='filter[date_from]'][value='2026-10-01']"
      assert_select "input[type=hidden][name='filter[date_to]'][value='2026-10-31']"
    end

    it "reviews every unfiled row when the page had any date, as before" do
      get bank_transactions_path(filter: { state: "unfiled" })
      assert_select "main a.btn[href='#{new_guessed_filing_path}']", text: "File 2 as guessed"

      get new_guessed_filing_path

      expect(rows.size).to eq(2)
    end

    it "goes back to the Unfiled state with the same range when it's filed" do
      guess = Budget::Guesser.new(budget).guess(in_range)

      post guessed_filing_path, params: { guessed: { in_range.id.to_s => guess.review_value }, filter: { date_from: "2026-10-01", date_to: "2026-10-31" } }

      expect(response).to redirect_to(bank_transactions_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", state: "unfiled" }))
      expect(in_range.reload).to be_filed
      expect(out_of_range.reload).to be_unfiled
    end
  end

  describe "the Import summary" do
    let(:csv_format) { create(:budget_csv_format, budget: budget, name: "Plain") }

    it "links its figures for what Filing rules filed and ignored to the Account's To review state" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      create(:budget_filing_rule, :ignore, budget: budget, text: "payment")
      import = account.imports.build(csv_format: csv_format, file_name: "sept.csv")
      import.run("2026-09-02,LOBLAWS #1234,-82.45\n2026-09-03,PAYMENT THANK YOU,-250.00\n2026-09-04,Paycheck,2800.00\n")

      get import_path(import)

      to_review = bank_transactions_path(filter: { state: "to_review", account: account.id })
      assert_select "a[href='#{to_review}']", text: "Review", count: 2
      expect(visible_text).to include("Filed by Filing rules 1 bank transaction · Review", "Ignored by Filing rules 1 bank transaction · Review")
    end

    it "has no link when rules acted on nothing" do
      import = account.imports.build(csv_format: csv_format, file_name: "sept.csv")
      import.run("2026-09-04,Paycheck,2800.00\n")

      get import_path(import)

      assert_select "a", text: "Review", count: 0
    end
  end
end
