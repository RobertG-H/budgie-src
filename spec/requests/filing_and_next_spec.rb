require "rails_helper"

# File and next, and Ignore and next: working through the unfiled bank transactions without going back to the list after each one. The next
# one is the first unfiled bank transaction older than this one in the list the form was opened from, in that list's order, and when none is
# older it wraps to the newest left, so working from the middle of the list still finishes it.
RSpec.describe "File and next", type: :request do
  include FilingHistory

  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:savings) { create(:budget_account, budget: budget, name: "Savings") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  # Newest first, the way the list shows them: alpha, bravo, delta (in Savings) and then charlie.
  let!(:alpha) { create(:budget_bank_transaction, account: account, description: "ALPHA MART", date: Date.new(2026, 9, 20), amount: -10) }
  let!(:bravo) { create(:budget_bank_transaction, account: account, description: "BRAVO MART", date: Date.new(2026, 9, 15), amount: -20) }
  let!(:delta) { create(:budget_bank_transaction, account: savings, description: "DELTA MART", date: Date.new(2026, 9, 12), amount: -40) }
  let!(:charlie) { create(:budget_bank_transaction, account: account, description: "CHARLIE MART", date: Date.new(2026, 9, 10), amount: -30) }

  before { sign_in_as budget.user }

  let(:filter) { { state: "unfiled", date_from: "2026-09-01", date_to: "2026-09-30" } }
  let(:bank_transactions_page) { bank_transactions_path(filter: filter) }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # What the form sends for a bank transaction's one record, which is all of its amount from Groceries.
  def record_for(bank_transaction, **attributes)
    { kind: "spend", envelope_id: groceries.id, description: bank_transaction.description, date: bank_transaction.date.iso8601, amount: bank_transaction.amount.abs.to_s, notes: "" }.merge(attributes)
  end

  def file_and_next(bank_transaction, from: "bank_transactions", filter: self.filter, page: nil, rule: nil, **record)
    params = { filing: { records: { "0" => record_for(bank_transaction, **record) }, rule: rule }.compact, next: "1" }
    params[:from] = from if from
    params[:filter] = filter if from == "bank_transactions"
    params[:page] = page if page
    post bank_transaction_filing_path(bank_transaction), params: params
  end

  def ignore_and_next(bank_transaction, from: "bank_transactions", filter: self.filter, page: nil)
    params = { next: "1" }
    params[:from] = from if from
    params[:filter] = filter if from == "bank_transactions"
    params[:page] = page if page
    post bank_transaction_ignore_path(bank_transaction), params: params
  end

  describe "the form's buttons" do
    it "are File and next (primary), File, Ignore and next and Cancel, when there's a next one to go to" do
      get new_bank_transaction_filing_path(bravo, from: "bank_transactions", filter: filter)

      assert_select "form" do
        assert_select "button[type=submit][name=next][value='1'].btn-primary", text: "File and next"
        assert_select "input[type=submit][value=File].btn:not(.btn-primary)"
        assert_select "button[type=submit][name=next][value='1'][formaction='#{bank_transaction_ignore_path(bravo)}'][formnovalidate].btn", text: "Ignore and next"
        assert_select "a.btn[href='#{bank_transactions_page}']", text: "Cancel"
      end
      assert_select "button", text: "Ignore", count: 0
      assert_select "input[type=submit][value='File and next']", count: 0
    end

    it "put File and next first, so Enter in a field files and goes on" do
      get new_bank_transaction_filing_path(bravo, from: "bank_transactions", filter: filter)

      submits = css_select("main form button[type=submit], main form input[type=submit]").map { |button| button["value"] == "File" ? "File" : button.text.squish }
      expect(submits).to eq([ "File and next", "File", "Ignore and next" ])
    end

    it "are File, Ignore and Cancel, as before, for the last unfiled bank transaction" do
      [ alpha, bravo, delta ].each { |other| create(:budget_spend_link, bank_transaction: other) }

      get new_bank_transaction_filing_path(charlie, from: "bank_transactions", filter: filter)

      assert_select "input[type=submit][value=File].btn-primary"
      assert_select "button[formaction='#{bank_transaction_ignore_path(charlie)}']", text: "Ignore"
      assert_select "button[name=next]", count: 0
      expect(visible_text).not_to include("and next")
    end

    it "are File, Ignore and Cancel when the form wasn't opened from a list, which has no next" do
      get new_bank_transaction_filing_path(bravo)

      assert_select "input[type=submit][value=File].btn-primary"
      assert_select "button", text: "Ignore"
      expect(visible_text).not_to include("and next")
    end

    it "are offered from an Account's page, and only for that Account's unfiled bank transactions" do
      get new_bank_transaction_filing_path(bravo, from: "account")
      assert_select "button[name=next]", text: "File and next"

      [ alpha, charlie ].each { |other| create(:budget_spend_link, bank_transaction: other) }
      get new_bank_transaction_filing_path(bravo, from: "account")
      assert_select "button[name=next]", count: 0
    end

    it "are offered when the Bank transactions page was filtered to an Account that has another unfiled one, and not when it hasn't" do
      get new_bank_transaction_filing_path(bravo, from: "bank_transactions", filter: filter.merge(account: account.id.to_s))
      assert_select "button[name=next]", text: "File and next"

      get new_bank_transaction_filing_path(delta, from: "bank_transactions", filter: filter.merge(account: savings.id.to_s))
      assert_select "button[name=next]", count: 0
    end

    it "start focus on File and next when there's an envelope to choose from, otherwise on the envelope" do
      get new_bank_transaction_filing_path(bravo, from: "bank_transactions", filter: filter)

      assert_select "select[autofocus]"
      assert_select "button[name=next][autofocus]", count: 0
    end
  end

  describe "File and next" do
    it "files it and goes to the next one's form, with the same way back, and says it was filed" do
      expect { file_and_next bravo, page: 2 }.to change(Budget::Spend, :count).by(1)

      expect(bravo.reload).to be_filed
      expect(response).to redirect_to(new_bank_transaction_filing_path(delta, from: "bank_transactions", filter: filter, page: 2))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed."
      assert_select "h1", text: "File bank transaction"
      expect(visible_text).to include("DELTA MART", "Savings")
      assert_select "input[type=hidden][name=from][value=bank_transactions]"
      assert_select "input[type=hidden][name='filter[state]'][value=unfiled]"
      assert_select "input[type=hidden][name=page][value='2']"
      assert_select "a.btn[href='#{bank_transactions_path(filter: filter, page: 2)}']", text: "Cancel"
    end

    it "goes on through the whole list, newest first, ending at the list with a clear message" do
      file_and_next alpha
      expect(response).to redirect_to(new_bank_transaction_filing_path(bravo, from: "bank_transactions", filter: filter))

      file_and_next bravo
      expect(response).to redirect_to(new_bank_transaction_filing_path(delta, from: "bank_transactions", filter: filter))

      file_and_next delta
      expect(response).to redirect_to(new_bank_transaction_filing_path(charlie, from: "bank_transactions", filter: filter))

      file_and_next charlie
      expect(response).to redirect_to(bank_transactions_page)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed. No more unfiled bank transactions."
      expect(Budget::BankTransaction.unfiled.count).to eq(0)
    end

    it "wraps to the newest unfiled one left when it was the oldest, so working from the middle of the list finishes it" do
      file_and_next charlie

      expect(response).to redirect_to(new_bank_transaction_filing_path(alpha, from: "bank_transactions", filter: filter))
    end

    it "stays in the Account the Bank transactions page was filtered to" do
      with_account = filter.merge(account: account.id.to_s)

      file_and_next bravo, filter: with_account

      expect(response).to redirect_to(new_bank_transaction_filing_path(charlie, from: "bank_transactions", filter: with_account))
    end

    it "stays in its own Account when it was opened from the Account's page" do
      file_and_next bravo, from: "account"

      expect(response).to redirect_to(new_bank_transaction_filing_path(charlie, from: "account"))
      follow_redirect!
      assert_select "a.btn[href='#{account_path(account)}']", text: "Cancel"
    end

    it "doesn't care about the state or the dates the list was filtered to, which don't matter to the unfiled ones" do
      all_states = { state: "ignored", date_from: "2020-01-01", date_to: "2020-01-31" }

      file_and_next bravo, filter: all_states

      expect(response).to redirect_to(new_bank_transaction_filing_path(delta, from: "bank_transactions", filter: all_states))
    end

    it "never goes to one that's filed or ignored" do
      delta.ignore
      create(:budget_spend_link, bank_transaction: charlie)

      file_and_next bravo

      expect(response).to redirect_to(new_bank_transaction_filing_path(alpha, from: "bank_transactions", filter: filter))
    end

    it "ends at where it was opened from with the message when none is left, as the last one does" do
      [ alpha, delta, charlie ].each { |other| create(:budget_spend_link, bank_transaction: other) }

      file_and_next bravo

      expect(response).to redirect_to(bank_transactions_page)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed. No more unfiled bank transactions."
    end

    it "ends at the Account's page from there" do
      [ alpha, charlie ].each { |other| create(:budget_spend_link, bank_transaction: other) }

      file_and_next bravo, from: "account"

      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed. No more unfiled bank transactions."
    end

    it "starts the next form on its own Guess, as any form does" do
      filed("DELTA MART EARLIER", groceries, amount: -40, account: savings)

      file_and_next bravo
      follow_redirect!

      expect(visible_text).to include("Guess: like DELTA MART EARLIER → Groceries")
      assert_select "select[name='filing[records][0][envelope_id]'] option[selected]", text: "Groceries"
    end

    it "is judged after the filing, so what a rule from the form files too is never the next one" do
      file_and_next alpha, rule: { make: "1", text: "mart", sweep: "1", account_id: "" }

      expect(Budget::BankTransaction.unfiled.count).to eq(0)
      expect(response).to redirect_to(bank_transactions_page)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed. The Filing rule also filed 3 other bank transactions. No more unfiled bank transactions."
    end

    it "says what a rule from the form did, above the next form" do
      create(:budget_bank_transaction, account: account, description: "BRAVO MART 2", date: Date.new(2026, 9, 5), amount: -7)

      file_and_next bravo, rule: { make: "1", text: "bravo mart", sweep: "1" }

      expect(response).to redirect_to(new_bank_transaction_filing_path(delta, from: "bank_transactions", filter: filter))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed. The Filing rule also filed 1 other bank transaction."
    end

    it "is refused as File is, with the whole form as it was entered and nothing moved on" do
      expect { file_and_next bravo, envelope_id: "" }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      expect(bravo.reload).to be_unfiled
      expect(visible_text).to include("BRAVO MART")
      assert_select "button[name=next]", text: "File and next"
      assert_select "input[type=hidden][name=from][value=bank_transactions]"
    end

    it "goes back to where it was opened from, as File does, when asked for no next" do
      post bank_transaction_filing_path(bravo), params: { filing: { records: { "0" => record_for(bravo) } }, from: "bank_transactions", filter: filter }

      expect(response).to redirect_to(bank_transactions_page)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed."
    end

    it "has no next when the form wasn't opened from a list: it goes to the Account and says only that it was filed" do
      file_and_next bravo, from: nil

      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed."
    end

    it "doesn't take a next from a page it doesn't know" do
      file_and_next bravo, from: "https://evil.example/"

      expect(response).to redirect_to(account_path(account))
      expect(response.location).not_to include("evil")
    end

    it "is not found for another user's bank transaction" do
      others = create(:budget_bank_transaction, description: "Someone else's")

      post bank_transaction_filing_path(others), params: { filing: { records: { "0" => record_for(others, envelope_id: groceries.id) } }, next: "1", from: "bank_transactions", filter: filter }

      expect(response).to have_http_status(:not_found)
    end

    it "never goes to another user's bank transaction" do
      create(:budget_bank_transaction, description: "Someone else's", date: Date.new(2026, 9, 11), amount: -5)

      file_and_next delta

      expect(response).to redirect_to(new_bank_transaction_filing_path(charlie, from: "bank_transactions", filter: filter))
    end

    it "costs no more queries however many bank transactions are unfiled" do
      few = count_queries { file_and_next bravo }

      create_list(:budget_bank_transaction, 40, account: account, date: Date.new(2026, 8, 1), amount: -3)
      many = count_queries { file_and_next alpha }

      expect(many).to eq(few)
    end
  end

  describe "Ignore and next" do
    it "ignores it and goes to the next one's form, with the same way back, and says it was ignored" do
      expect { ignore_and_next bravo, page: 2 }.to change { bravo.reload.ignored? }.from(false).to(true)

      expect(response).to redirect_to(new_bank_transaction_filing_path(delta, from: "bank_transactions", filter: filter, page: 2))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction ignored."
      expect(visible_text).to include("DELTA MART")
    end

    it "wraps, and stays in the Account of an Account's page" do
      ignore_and_next charlie, from: "account"
      expect(response).to redirect_to(new_bank_transaction_filing_path(alpha, from: "account"))
    end

    it "ends at where it was opened from with the message when none is left" do
      [ alpha, delta, charlie ].each { |other| create(:budget_spend_link, bank_transaction: other) }

      ignore_and_next bravo

      expect(response).to redirect_to(bank_transactions_page)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction ignored. No more unfiled bank transactions."
    end

    it "makes the rule from the form first, and says so, as Ignore does" do
      post bank_transaction_ignore_path(bravo), params: { filing: { records: { "0" => record_for(bravo) }, rule: { make: "1", text: "bravo mart" } }, next: "1", from: "bank_transactions", filter: filter }

      expect(budget.filing_rules.sole).to have_attributes(text: "bravo mart", outcome: "ignore")
      expect(response).to redirect_to(new_bank_transaction_filing_path(delta, from: "bank_transactions", filter: filter))
    end

    it "is refused when the bank transaction is filed, saying why, and goes back to where it was opened from" do
      create(:budget_spend_link, bank_transaction: bravo)

      ignore_and_next bravo

      expect(response).to redirect_to(bank_transactions_page)
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is filed. Un-file it before ignoring it."
    end

    it "is refused as Ignore is when the rule from the form is wrong, with the whole form as it was" do
      post bank_transaction_ignore_path(bravo), params: { filing: { records: { "0" => record_for(bravo) }, rule: { make: "1", text: "shell" } }, next: "1", from: "bank_transactions", filter: filter }

      expect(response).to have_http_status(:unprocessable_content)
      expect(bravo.reload).to be_unfiled
      assert_select "button[name=next]", text: "File and next"
    end

    it "goes back to where it was opened from, as Ignore does, when asked for no next" do
      post bank_transaction_ignore_path(bravo), params: { from: "bank_transactions", filter: filter }

      expect(response).to redirect_to(bank_transactions_page)
    end

    it "is not found for another user's bank transaction" do
      others = create(:budget_bank_transaction, description: "Someone else's")

      post bank_transaction_ignore_path(others), params: { next: "1", from: "bank_transactions", filter: filter }

      expect(response).to have_http_status(:not_found)
    end

    it "costs no more queries however many bank transactions are unfiled" do
      few = count_queries { ignore_and_next bravo }

      create_list(:budget_bank_transaction, 40, account: account, date: Date.new(2026, 8, 1), amount: -3)
      many = count_queries { ignore_and_next alpha }

      expect(many).to eq(few)
    end
  end
end
