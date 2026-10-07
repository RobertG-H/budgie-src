require "rails_helper"

# Several bank transactions at once, ticked on the Bank transactions page: file them to one envelope, ignore them, un-file them or un-ignore them, each all or
# none, and Mark reviewed for what a Filing rule did (ADR 0017), which marks the ones still to review. Each goes back to the same page of the same list.
RSpec.describe "Bulk bank transactions", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:visa) { create(:budget_account, budget: budget, name: "Visa") }
  let!(:travel) { create(:budget_envelope, budget: budget, name: "Travel") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  before do
    travel_to Time.utc(2026, 10, 14, 16)
    sign_in_as budget.user
  end

  def make(description = "Hotel", *traits, account: chequing, amount: -100, date: Date.new(2026, 10, 3))
    create(:budget_bank_transaction, *traits, account: account, description: description, amount: amount, date: date).reload
  end

  def ids(*rows)
    rows.flatten.map(&:id)
  end

  let(:filter) { { state: "unfiled" } }

  def file_selected(rows, envelope: travel, filter: self.filter, page: nil)
    post bulk_bank_transaction_filing_path, params: { ids: ids(rows), envelope_id: envelope&.id, filter: filter, page: page }.compact
  end

  def rows
    css_select("main ul.list li").map { |row| row.text.squish }
  end

  def checkbox_for(row)
    css_select("input[type=checkbox][name='ids[]'][value='#{row.id}']").first
  end

  describe "the bar and the checkboxes" do
    let!(:hotel) { make("Hotel") }
    let!(:flight) { make("Flight", date: Date.new(2026, 10, 2)) }

    it "is above the Unfiled list, with a checkbox on each row, an envelope to file to and File selected and Ignore selected" do
      get bank_transactions_path(filter: filter)

      assert_select "form#bulk-bank-transactions[method=post][action='#{bulk_bank_transaction_filing_path}']" do
        assert_select "select[name=envelope_id][required]"
        assert_select "button.btn-primary", text: "File selected"
        assert_select "button[formaction='#{bulk_bank_transaction_ignore_path}'][formnovalidate]", text: "Ignore selected"
        assert_select "input[type=hidden][name='filter[state]'][value=unfiled]"
        assert_select "button", count: 2
      end
      expect(css_select("select[name=envelope_id] option").map { |option| option.text.squish }).to eq([ "Choose an envelope", "Groceries", "Travel" ])
      expect(css_select("input[type=checkbox][name='ids[]']").map { |box| [ box["form"], box["value"].to_i ] }).to eq([ [ "bulk-bank-transactions", hotel.id ], [ "bulk-bank-transactions", flight.id ] ])
    end

    it "offers only the envelopes in use to file to" do
      travel.archive!

      get bank_transactions_path(filter: filter)

      expect(css_select("select[name=envelope_id] option").map { |option| option.text.squish }).to eq([ "Choose an envelope", "Groceries" ])
    end

    it "keeps the page's filter and page in the bar, so every action comes back to them" do
      get bank_transactions_path(filter: filter.merge(account: chequing.id.to_s))

      assert_select "form#bulk-bank-transactions input[type=hidden][name='filter[account]'][value='#{chequing.id}']"
      assert_select "form#bulk-bank-transactions input[type=hidden][name=page]", count: 0
    end

    it "is JavaScript's to enhance: the bulk-selection controller holds the bar and the list, and select-all is hidden until it's there" do
      get bank_transactions_path(filter: filter)

      assert_select "div[data-controller=bulk-selection]" do
        assert_select "form#bulk-bank-transactions label[hidden] input[type=checkbox][data-bulk-selection-target=all]"
        assert_select "form#bulk-bank-transactions", text: /Select all 2 on this page/
        assert_select "ul.list"
      end
      assert_select "form#bulk-bank-transactions button[data-bulk-selection-target=action]", count: 2
    end

    it "gives each checkbox a cell of its own outside the row's link, which still opens the filing form, with a tap target at least 44px wide" do
      get bank_transactions_path(filter: filter)

      box = checkbox_for(hotel)
      expect(box.ancestors("a")).to be_empty
      expect(box.ancestors("label").first["class"]).to include("w-12")
      expect(box["aria-label"]).to eq("Select Hotel")
      row = css_select("main ul.list li").find { |item| item.text.include?("Hotel") }
      expect(row.at_css("a.list-row")["href"]).to start_with(new_bank_transaction_filing_path(hotel))
      expect(row.at_css("a.list-row")["class"]).to include("pl-12")
    end

    it "says what each row is, for the controller: its direction, state and how many records it was filed as" do
      get bank_transactions_path(filter: filter)

      expect(checkbox_for(hotel)["data-direction"]).to eq("out")
      expect(checkbox_for(hotel)["data-records"]).to eq("0")
    end

    it "has Un-file selected, which asks first, and Un-ignore selected, only where they can apply, and no bar in All" do
      make("Filed one", :filed)
      make("Ignored one", :ignored)

      get bank_transactions_path(filter: { state: "filed" })
      expect(css_select("form#bulk-bank-transactions button").map { |button| button.text.squish }).to eq([ "Un-file selected" ])
      assert_select "form#bulk-bank-transactions button[name=_method][value=delete][formaction='#{bulk_bank_transaction_filing_path}'][data-turbo-confirm]"

      get bank_transactions_path(filter: { state: "ignored" })
      expect(css_select("form#bulk-bank-transactions button").map { |button| button.text.squish }).to eq([ "Un-ignore selected" ])
      assert_select "form#bulk-bank-transactions button[name=_method][value=delete][formaction='#{bulk_bank_transaction_ignore_path}']"

      get bank_transactions_path
      assert_select "form#bulk-bank-transactions", count: 0
      assert_select "input[type=checkbox]", count: 0
    end

    it "has Mark reviewed, Un-file selected and Un-ignore selected in To review" do
      make("By a rule", :filed, :by_rule)

      get bank_transactions_path(filter: { state: "to_review" })

      expect(css_select("form#bulk-bank-transactions button").map { |button| button.text.squish }).to eq([ "Mark reviewed", "Un-file selected", "Un-ignore selected" ])
      assert_select "button[formaction='#{bulk_bank_transaction_review_path}'].btn-primary", text: "Mark reviewed"
    end

    it "is left out with the list when there's nothing to show, and on an Account's page" do
      get bank_transactions_path(filter: { state: "to_review" })
      assert_select "form#bulk-bank-transactions", count: 0

      get account_path(chequing)
      assert_select "form#bulk-bank-transactions", count: 0
      assert_select "input[name='ids[]']", count: 0
    end
  end

  describe "File selected" do
    let!(:hotel) { make("Hotel", amount: -100, date: Date.new(2026, 10, 3)) }
    let!(:flight) { make("Flight", amount: -250, date: Date.new(2026, 10, 2), account: visa) }
    let!(:refund) { make("Hotel refund", amount: 40, date: Date.new(2026, 10, 5)) }

    it "files money out as Spends and money in as Refunds to the one envelope, and says so" do
      expect { file_selected([ hotel, flight, refund ]) }.to change(Budget::Spend, :count).by(2).and change(Budget::Refund, :count).by(1)

      expect(travel.spends.pluck(:description, :amount)).to contain_exactly([ "Hotel", 100 ], [ "Flight", 250 ])
      expect(travel.refunds.sole).to have_attributes(description: "Hotel refund", amount: 40, date: Date.new(2026, 10, 5), notes: "")
      expect(response).to redirect_to(bank_transactions_path(filter: filter))
      follow_redirect!
      assert_select "[role=status]", text: "Filed 2 Spends and 1 Refund to Travel."
      expect(rows).to eq([])
    end

    it "makes no Filing rule, offers none and notes none, so nothing it files is to review" do
      file_selected([ hotel, flight ])

      expect(Budget::FilingRule.count).to eq(0)
      expect([ hotel, flight ].map { |row| row.reload.filing_rule_id }).to all(be_nil)
      expect(Budget::BankTransaction.to_review).to be_empty
    end

    it "comes back to the same page of the same filter, with the Account and the dates" do
      filter = { state: "unfiled", account: chequing.id.to_s, date_from: "2026-10-01", date_to: "2026-10-31" }

      file_selected([ hotel ], filter: filter, page: 2)

      expect(response).to redirect_to(bank_transactions_path(filter: filter, page: 2))
    end

    it "files none, comes back as the page with the selection and the envelope kept, and names the row, when one was filed in another tab" do
      create(:budget_spend_link, bank_transaction: hotel, spend: create(:budget_spend, envelope: groceries, amount: 100))

      expect { file_selected([ hotel, flight ]) }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Nothing was filed. Hotel: This bank transaction is already filed."
      expect(flight.reload).to be_unfiled
      assert_select "h1", text: "Bank transactions"
      expect(checkbox_for(flight)["checked"]).to eq("checked")
      assert_select "select[name=envelope_id] option[selected][value='#{travel.id}']"
    end

    it "files none, and names the row, when a row went from Splitwise" do
      splitwise = create(:budget_account, :synced, budget: budget)
      gone = create(:budget_bank_transaction, :removed, account: splitwise, description: "Gone")

      file_selected([ hotel, gone ])

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Nothing was filed. Gone: This bank transaction was deleted in Splitwise, so it can't be filed."
      expect(hotel.reload).to be_unfiled
    end

    it "files none when the envelope was archived in the meantime, in the words filing as guessed uses" do
      travel.archive!

      file_selected([ hotel ])

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Nothing was filed. Hotel: Envelope is archived."
    end

    it "asks for an envelope when none was chosen, and for a bank transaction when none was ticked, and changes nothing" do
      file_selected([ hotel ], envelope: nil)
      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Choose an envelope to file them to."

      file_selected([])
      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Choose at least one bank transaction."
      expect(hotel.reload).to be_unfiled
    end

    it "files none to another budget's envelope, which is no envelope of the budget's" do
      other = create(:budget_envelope, name: "Theirs")

      file_selected([ hotel ], envelope: other)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Nothing was filed. Hotel: Envelope can't be blank."
      expect(hotel.reload).to be_unfiled
    end

    it "is a 404 for another user's bank transaction, and files nothing of the others" do
      theirs = create(:budget_bank_transaction, account: create(:budget_account, budget: create(:budget)))

      expect { file_selected([ hotel, theirs ]) }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:not_found)
      expect(hotel.reload).to be_unfiled
    end

    it "takes at most a page's worth, which is all there is a checkbox for" do
      file_selected(Array.new(51) { hotel })
      expect(response).to have_http_status(:redirect)

      post bulk_bank_transaction_filing_path, params: { ids: (1..51).to_a, envelope_id: travel.id, filter: filter }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Choose at most 50 bank transactions at a time."
    end

    it "requires sign-in" do
      delete session_path

      file_selected([ hotel ])

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "Ignore selected and Un-ignore selected" do
    let!(:first) { make("First") }
    let!(:second) { make("Second", account: visa) }

    it "ignores them all, and goes back to the same page" do
      post bulk_bank_transaction_ignore_path, params: { ids: ids(first, second), filter: filter, page: 2 }

      expect([ first, second ].map { |row| row.reload.ignored? }).to all(be(true))
      expect(response).to redirect_to(bank_transactions_path(filter: filter, page: 2))
      expect(flash[:notice]).to eq("2 bank transactions ignored.")
      expect(Budget::BankTransaction.to_review).to be_empty
    end

    it "ignores none, naming the row, when one was filed in another tab" do
      create(:budget_spend_link, bank_transaction: second, spend: create(:budget_spend, envelope: groceries, amount: 100))

      post bulk_bank_transaction_ignore_path, params: { ids: ids(first, second), filter: filter }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Nothing was ignored. Second: This bank transaction is filed. Un-file it before ignoring it."
      expect(first.reload).not_to be_ignored
      expect(checkbox_for(first)["checked"]).to eq("checked")
    end

    it "un-ignores them all, which are no longer a rule's, and says how many" do
      ignored = make("Ignored", :ignored, :by_rule)
      other = make("Other ignored", :ignored)

      delete bulk_bank_transaction_ignore_path, params: { ids: ids(ignored, other), filter: { state: "ignored", date_from: "2026-10-01", date_to: "2026-10-31" } }

      expect([ ignored, other ].map { |row| row.reload.ignored? }).to all(be(false))
      expect(ignored.filing_rule_id).to be_nil
      expect(response).to redirect_to(bank_transactions_path(filter: { state: "ignored", date_from: "2026-10-01", date_to: "2026-10-31" }))
      expect(flash[:notice]).to eq("2 bank transactions un-ignored.")
    end

    it "un-ignores none, naming the row, when one isn't ignored" do
      ignored = make("Ignored", :ignored)

      delete bulk_bank_transaction_ignore_path, params: { ids: ids(ignored, first), filter: { state: "ignored" } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Nothing was un-ignored. First: This bank transaction isn't ignored."
      expect(ignored.reload).to be_ignored
    end

    it "is a 404 for another user's, and changes nothing" do
      theirs = create(:budget_bank_transaction, account: create(:budget_account, budget: create(:budget)))

      post bulk_bank_transaction_ignore_path, params: { ids: ids(first, theirs), filter: filter }

      expect(response).to have_http_status(:not_found)
      expect(first.reload).not_to be_ignored
    end
  end

  describe "Un-file selected" do
    let!(:first) { make("First", :filed) }
    let!(:second) { make("Second", :filed, :by_rule, amount: 20) }

    it "deletes the records they were filed as, which leaves them unfiled, and goes back to the same page" do
      filter = { state: "filed", date_from: "2026-10-01", date_to: "2026-10-31" }
      delete bulk_bank_transaction_filing_path, params: { ids: ids(first, second), filter: filter, page: 3 }

      expect([ first, second ].map { |row| row.reload.unfiled? }).to all(be(true))
      expect([ Budget::Spend.count, Budget::Deposit.count ]).to eq([ 0, 0 ])
      expect(response).to redirect_to(bank_transactions_path(filter: filter, page: 3))
      expect(flash[:notice]).to eq("2 bank transactions unfiled.")
    end

    it "un-files none, naming the row, when one isn't filed, and keeps the selection" do
      ignored = make("Ignored one", :ignored)

      delete bulk_bank_transaction_filing_path, params: { ids: ids(first, ignored), filter: { state: "to_review" } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Nothing was un-filed. Ignored one: This bank transaction isn't filed."
      expect(first.reload).to be_filed
    end

    it "is a 404 for another user's" do
      theirs = create(:budget_bank_transaction, :filed, account: create(:budget_account, budget: create(:budget)))

      delete bulk_bank_transaction_filing_path, params: { ids: ids(first, theirs), filter: { state: "filed" } }

      expect(response).to have_http_status(:not_found)
      expect(first.reload).to be_filed
    end
  end

  describe "Mark reviewed" do
    let!(:filed) { make("Filed by a rule", :filed, :by_rule) }
    let!(:ignored) { make("Ignored by a rule", :ignored, :by_rule) }

    it "marks the ones that are to review, says how many, and goes back to the same page" do
      post bulk_bank_transaction_review_path, params: { ids: ids(filed, ignored), filter: { state: "to_review" }, page: 2 }

      expect([ filed, ignored ].map { |row| row.reload.to_review? }).to all(be(false))
      expect(response).to redirect_to(bank_transactions_path(filter: { state: "to_review" }, page: 2))
      expect(flash[:notice]).to eq("2 bank transactions marked reviewed.")
    end

    it "is lenient: a row that's no longer to review, such as one un-filed in another tab, is skipped and doesn't refuse the rest" do
      gone = make("Un-filed since", :filed, :by_rule)
      gone.unfile

      post bulk_bank_transaction_review_path, params: { ids: ids(filed, gone), filter: { state: "to_review" } }

      expect(response).to have_http_status(:redirect)
      expect(filed.reload).not_to be_to_review
      expect(flash[:notice]).to eq("1 bank transaction marked reviewed. 1 other wasn't to review any more.")
    end

    it "is a 404 for another user's, and marks nothing" do
      theirs = create(:budget_bank_transaction, :filed, :by_rule, account: create(:budget_account, budget: create(:budget)))

      post bulk_bank_transaction_review_path, params: { ids: ids(filed, theirs), filter: { state: "to_review" } }

      expect(response).to have_http_status(:not_found)
      expect(filed.reload).to be_to_review
    end

    it "says to choose one when none is ticked" do
      post bulk_bank_transaction_review_path, params: { filter: { state: "to_review" } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: "Choose at least one bank transaction."
    end
  end

  it "runs the same number of queries for a page of 5 rows as for 50, whichever it does" do
    counts = [ 5, 50 ].map do |count|
      created = Array.new(count) { |n| make("Bulk #{count} #{n}", date: Date.new(2026, 10, 1) + (n % 20)) }

      [ count_queries { file_selected(created) }, count_queries { post bulk_bank_transaction_ignore_path, params: { ids: ids(created), filter: filter } } ]
    end

    expect(counts.first).to eq(counts.last)
  end
end
