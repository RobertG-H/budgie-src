require "rails_helper"

RSpec.describe "Filing bank transactions", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }
  let!(:money_out) { create(:budget_bank_transaction, account: account, description: "COSTCO #123", date: Date.new(2026, 9, 12), amount: -100) }
  let!(:money_in) { create(:budget_bank_transaction, account: account, description: "ACME PAYROLL", date: Date.new(2026, 9, 30), amount: 3000) }
  let(:others_bank_transaction) { create(:budget_bank_transaction, description: "Someone else's") }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # What a record's envelope select offers, as one line of text per option.
  def choices
    css_select("select[name='filing[records][0][envelope_id]'] option").map { |option| option.text.strip }
  end

  # What the form sends for one record.
  def record_params(**attributes)
    { kind: "spend", envelope_id: groceries.id, description: "Costco run", date: "2026-09-12", amount: "100", notes: "Bulk buy" }.merge(attributes)
  end

  describe "GET /bank_transactions/:bank_transaction_id/filing/new" do
    it "shows the bank transaction, and a form to file it as one record, with a File button, an Ignore button and Cancel" do
      get new_bank_transaction_filing_path(money_out, from: "account")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "File bank transaction · Budgie"
      assert_select "h1", text: "File bank transaction"
      expect(visible_text).to include("Chequing", "Sep 12, 2026", "COSTCO #123", "-$100.00", "Money out")
      assert_select "form[action='#{bank_transaction_filing_path(money_out)}'][method=post]" do
        assert_select "input[type=submit][value=File]"
        assert_select "button[formaction='#{bank_transaction_ignore_path(money_out)}'][formnovalidate][name=_method][value=post]", text: "Ignore"
        assert_select "input[type=hidden][name=from][value=account]"
      end
      assert_select "a.btn[href='#{account_path(account)}']", text: "Cancel"
    end

    it "starts with the bank transaction's date and description, and its whole amount as a positive figure, and no envelope" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "input[name='filing[records][0][description]'][value='COSTCO #123']"
      assert_select "input[type=date][name='filing[records][0][date]'][value='2026-09-12']"
      assert_select "input[type=number][name='filing[records][0][amount]'][step='0.01'][value='100.00']"
      assert_select "select[name='filing[records][0][envelope_id]'] option[selected]", count: 0
      assert_select "textarea[name='filing[records][0][notes]']", text: ""
    end

    it "files money out as a Spend, which isn't a choice" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "input[type=hidden][name='filing[records][0][kind]'][value=spend]"
      assert_select "input[type=radio][name='filing[records][0][kind]']", count: 0
    end

    it "offers money in as a Deposit or a Refund, starting as a Deposit" do
      get new_bank_transaction_filing_path(money_in)

      assert_select "input[type=radio][name='filing[records][0][kind]']", count: 2
      assert_select "input[type=radio][name='filing[records][0][kind]'][value=deposit][checked]"
      assert_select "input[type=radio][name='filing[records][0][kind]'][value=refund]:not([checked])"
      assert_select "input[type=hidden][name='filing[records][0][kind]']", count: 0
      expect(visible_text).to include("Money in", "$3,000.00")
    end

    it "offers a Deposit the month of its date or the month after, starting with the date's" do
      get new_bank_transaction_filing_path(money_in)

      assert_select "input[type=radio][name='filing[records][0][month]'][value='2026-09-01']"
      assert_select "input[type=radio][name='filing[records][0][month]'][value='2026-10-01']"
      expect(visible_text).to include("September 2026", "October 2026")
    end

    it "offers the budget's envelopes in use, alphabetically after a prompt, and no one else's or archived ones" do
      create(:budget_envelope, budget: budget, name: "Archived", archived_at: Time.current)
      create(:budget_envelope, name: "Someone else's")

      get new_bank_transaction_filing_path(money_out)

      expect(choices).to eq([ "Choose an envelope", "Groceries", "Household" ])
    end

    it "carries which page it was opened from, so saving, ignoring or cancelling can go back" do
      get new_bank_transaction_filing_path(money_out, from: "unfiled")

      assert_select "input[type=hidden][name=from][value=unfiled]"
      assert_select "a.btn[href='#{unfiled_bank_transactions_path}']", text: "Cancel"
    end

    it "goes back to the Account when it isn't told where it was opened from, or is told something else" do
      [ nil, "", "nowhere", "https://evil.example/", "//evil.example" ].each do |from|
        get new_bank_transaction_filing_path(money_out, from: from)

        assert_select "a.btn[href='#{account_path(account)}']", text: "Cancel"
        assert_select "form input[type=hidden][name=from]", count: 0
        expect(response.body).not_to include("evil")
      end
    end

    it "says a bank transaction that's filed or ignored can't be filed, and goes back" do
      filed = create(:budget_bank_transaction, :filed, account: account)
      ignored = create(:budget_bank_transaction, :ignored, account: account)

      get new_bank_transaction_filing_path(filed, from: "unfiled")
      expect(response).to redirect_to(unfiled_bank_transactions_path)
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is already filed."

      get new_bank_transaction_filing_path(ignored, from: "account")
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is ignored. Un-ignore it first."
    end

    it "is not found for another user's bank transaction" do
      get new_bank_transaction_filing_path(others_bank_transaction)

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get new_bank_transaction_filing_path(money_out)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /bank_transactions/:bank_transaction_id/filing" do
    def file(bank_transaction = money_out, records: [ record_params ], from: nil)
      params = { filing: { records: records.each_with_index.to_h { |record, index| [ index.to_s, record ] } } }
      params[:from] = from if from
      post bank_transaction_filing_path(bank_transaction), params: params
    end

    it "files a Spend from the envelope, and goes back to the Account with a notice" do
      expect { file }.to change(groceries.spends, :count).by(1)

      expect(groceries.spends.sole).to have_attributes(description: "Costco run", date: Date.new(2026, 9, 12), amount: 100, notes: "Bulk buy")
      expect(money_out.reload).to be_filed
      expect(money_out.spend_links.sole.spend).to eq(groceries.spends.sole)
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed."
    end

    it "files money in as a Deposit, for the month chosen" do
      file money_in, records: [ { kind: "deposit", description: "Paycheck", date: "2026-09-30", month: "2026-10-01", amount: "3000", notes: "" } ]

      expect(budget.deposits.sole).to have_attributes(description: "Paycheck", date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1), amount: 3000)
      expect(money_in.reload).to be_filed
    end

    it "files money in as a Refund to an envelope" do
      file money_in, records: [ { kind: "refund", envelope_id: household.id, description: "Hydro rebate", date: "2026-09-30", amount: "3000" } ]

      expect(household.refunds.sole).to have_attributes(description: "Hydro rebate", amount: 3000)
      expect(money_in.reload.refund_links.sole.refund).to eq(household.refunds.sole)
    end

    it "goes back to the page it was opened from, the Unfiled list or the Account" do
      file from: "unfiled"
      expect(response).to redirect_to(unfiled_bank_transactions_path)

      file money_in, records: [ { kind: "deposit", description: "Paycheck", date: "2026-09-30", amount: "3000" } ], from: "account"
      expect(response).to redirect_to(account_path(account))
    end

    it "is refused when the record isn't the whole amount, saying by how much, and keeps what was entered" do
      expect { file records: [ record_params(amount: "60") ] }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "The records add up to $60.00, which is $40.00 less than the bank transaction's $100.00."
      assert_select "input[name='filing[records][0][amount]'][value='60']"
      assert_select "input[name='filing[records][0][description]'][value='Costco run']"
      assert_select "select[name='filing[records][0][envelope_id]'] option[selected][value='#{groceries.id}']"
      assert_select "textarea[name='filing[records][0][notes]']", text: "Bulk buy"
      expect(money_out.reload).to be_unfiled
    end

    it "is refused when the record has something wrong with it, by the field, as a typed-in record would be" do
      expect { file records: [ record_params(envelope_id: "", description: "", amount: "1.005") ] }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount can't have more than 2 decimal places"
      assert_select "select[name='filing[records][0][envelope_id]'][aria-invalid=true]"
      assert_select "input[name='filing[records][0][description]'][aria-invalid=true]"
    end

    it "says another budget's envelope is no envelope, as for a Spend" do
      others = create(:budget_envelope, name: "Someone else's")

      expect { file records: [ record_params(envelope_id: others.id) ] }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      expect(response.body).not_to include("Someone else")
    end

    it "says an archived envelope is archived, and creates nothing" do
      groceries.update_column(:archived_at, Time.current)

      expect { file }.not_to change(Budget::Spend, :count)

      assert_select "[role=alert] li", text: "Envelope is archived"
    end

    it "refuses money in as a Spend, and money out as a Deposit or a Refund" do
      file money_in, records: [ record_params(amount: "3000") ]
      assert_select "[role=alert] li", text: "Kind must be Deposit or Refund, since the money came in"

      file records: [ record_params(kind: "deposit") ]
      assert_select "[role=alert] li", text: "Kind must be Spend, since the money went out"

      file records: [ record_params(kind: "refund") ]
      assert_select "[role=alert] li", text: "Kind must be Spend, since the money went out"

      expect(Budget::Spend.count + Budget::Deposit.count + Budget::Refund.count).to eq(0)
    end

    it "refuses a month that isn't the date's or the month after" do
      file money_in, records: [ { kind: "deposit", description: "Paycheck", date: "2026-09-30", month: "2026-12-01", amount: "3000" } ]

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Ready to Assign in must be September 2026 or October 2026"
    end

    it "files once for a double submit, the second saying it's filed" do
      file
      file

      expect(budget.spends.count).to eq(1)
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is already filed."
    end

    it "is refused for a bank transaction that's ignored, and files nothing" do
      money_out.ignore

      expect { file }.not_to change(Budget::Spend, :count)

      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is ignored. Un-ignore it first."
    end

    it "is not found for another user's bank transaction, which it files nothing from" do
      expect { file others_bank_transaction }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "never takes the budget, the envelope's budget or the bank transaction from the params" do
      other = create(:budget)

      file records: [ record_params.merge(budget_id: other.id, bank_transaction_id: money_in.id, id: 1) ]

      expect(money_out.reload).to be_filed
      expect(money_in.reload).to be_unfiled
      expect(other.spends).to be_empty
    end

    it "is a bad request without any records" do
      post bank_transaction_filing_path(money_out), params: { from: "account" }

      expect(response).to have_http_status(:bad_request)
      expect(money_out.reload).to be_unfiled
    end

    it "requires sign-in" do
      delete session_path

      file

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "DELETE /bank_transactions/:bank_transaction_id/filing, un-filing" do
    let!(:filed) { create(:budget_bank_transaction, :filed, account: account, amount: -50) }

    it "deletes the records it was filed as, which makes it unfiled, and goes back with a notice" do
      expect { delete bank_transaction_filing_path(filed), params: { from: "account" } }.to change(Budget::Spend, :count).by(-1).and change(Budget::SpendLink, :count).by(-1)

      expect(filed.reload).to be_unfiled
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction unfiled."
    end

    it "is refused for one that isn't filed, saying so" do
      expect { delete bank_transaction_filing_path(money_out), params: { from: "account" } }.not_to change(Budget::Spend, :count)

      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction isn't filed."
    end

    it "is not found for another user's bank transaction, which it doesn't un-file" do
      theirs = create(:budget_bank_transaction, :filed)

      expect { delete bank_transaction_filing_path(theirs) }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST and DELETE /bank_transactions/:bank_transaction_id/ignore" do
    it "ignores an unfiled bank transaction, and goes back to the page it was opened from with a notice" do
      post bank_transaction_ignore_path(money_out), params: { from: "unfiled" }

      expect(money_out.reload).to be_ignored
      expect(response).to redirect_to(unfiled_bank_transactions_path)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction ignored."
    end

    it "ignores from the filing form, whatever else the form has in it" do
      post bank_transaction_ignore_path(money_out), params: { from: "account", filing: { records: { "0" => record_params } } }

      expect(money_out.reload).to be_ignored
      expect(Budget::Spend.count).to eq(0)
      expect(response).to redirect_to(account_path(account))
    end

    it "is refused for one that's filed, saying so" do
      filed = create(:budget_bank_transaction, :filed, account: account)

      post bank_transaction_ignore_path(filed), params: { from: "account" }

      expect(filed.reload).not_to be_ignored
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is filed. Un-file it before ignoring it."
    end

    it "is refused for one that's already ignored" do
      money_out.ignore

      post bank_transaction_ignore_path(money_out), params: { from: "account" }

      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is already ignored."
    end

    it "un-ignores, which makes it unfiled again" do
      money_out.ignore

      delete bank_transaction_ignore_path(money_out), params: { from: "account" }

      expect(money_out.reload).to be_unfiled
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction un-ignored."
    end

    it "is refused to un-ignore one that isn't ignored" do
      delete bank_transaction_ignore_path(money_out)

      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction isn't ignored."
    end

    it "is not found for another user's bank transaction, which it doesn't ignore" do
      post bank_transaction_ignore_path(others_bank_transaction)

      expect(response).to have_http_status(:not_found)
      expect(others_bank_transaction.reload).to be_unfiled
    end
  end
end
