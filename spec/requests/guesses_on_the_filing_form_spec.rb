require "rails_helper"

# When no active Filing rule fits an unfiled bank transaction, the filing form starts on Budgie's Guess: the kind and envelope the Budget's
# similar bank transactions were filed as, labelled with why (ADR 0013). It only suggests, so nothing is made until the person files.
RSpec.describe "A Guess on the filing form", type: :request do
  include FilingHistory

  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  def selected_envelope(index = 0)
    css_select("select[name='filing[records][#{index}][envelope_id]'] option[selected]").map { |option| option.text.strip }
  end

  describe "GET /bank_transactions/:bank_transaction_id/filing/new" do
    it "starts money out as a Spend from the envelope the Guess is, and says why" do
      filed("COSTCO #12", groceries)
      row = unfiled("COSTCO #123", amount: -100)

      get new_bank_transaction_filing_path(row, from: "bank_transactions")

      expect(response).to have_http_status(:ok)
      expect(selected_envelope).to eq([ "Groceries" ])
      assert_select "input[type=hidden][name='filing[records][0][kind]'][value=spend]"
      expect(visible_text).to include("Guess: like COSTCO #12 → Groceries")
    end

    it "starts money in as a Deposit when the Guess is one, which has no envelope" do
      filed("ACME PAYROLL SEP", amount: 2800)
      row = unfiled("ACME PAYROLL OCT", amount: 2800)

      get new_bank_transaction_filing_path(row)

      assert_select "input[type=radio][name='filing[records][0][kind]'][value=deposit][checked]"
      assert_select "input[type=radio][name='filing[records][0][kind]'][value=refund]:not([checked])"
      expect(selected_envelope).to be_empty
      expect(visible_text).to include("Guess: like ACME PAYROLL SEP → Deposit")
    end

    it "starts money in as a Refund to an envelope when the Guess is one" do
      filed("LOBLAWS RETURN", groceries, amount: 18.75)
      row = unfiled("LOBLAWS RETURN #88", amount: 9.5)

      get new_bank_transaction_filing_path(row)

      assert_select "input[type=radio][name='filing[records][0][kind]'][value=refund][checked]"
      assert_select "input[type=radio][name='filing[records][0][kind]'][value=deposit]:not([checked])"
      expect(selected_envelope).to eq([ "Groceries" ])
      expect(visible_text).to include("Guess: like LOBLAWS RETURN → Refund to Groceries")
    end

    it "keeps the bank's description, date and whole amount, and still offers Always file like this" do
      filed("COSTCO #12", groceries)
      row = unfiled("COSTCO #123", amount: -100)

      get new_bank_transaction_filing_path(row)

      assert_select "input[name='filing[records][0][description]'][value='COSTCO #123']"
      assert_select "input[type=date][name='filing[records][0][date]'][value='2026-10-02']"
      assert_select "input[type=number][name='filing[records][0][amount]'][value='100.00']"
      assert_select "input[type=checkbox][name='filing[rule][make]'][checked]"
      assert_select "input[type=text][name='filing[rule][text]'][value='costco']"
    end

    it "has no Guess, and starts as it always has, for a bank transaction nothing is like" do
      filed("COSTCO #12", groceries)
      row = unfiled("SHELL OIL #55", amount: -100)

      get new_bank_transaction_filing_path(row)

      expect(response).to have_http_status(:ok)
      expect(selected_envelope).to be_empty
      expect(visible_text).not_to include("Guess")
    end

    it "has no Guess when an active Filing rule fits it, since the rule would file it" do
      filed("COSTCO #12", groceries)
      create(:budget_filing_rule, budget: budget, envelope: household, text: "costco")
      row = unfiled("COSTCO #123", amount: -100)

      get new_bank_transaction_filing_path(row)

      expect(selected_envelope).to be_empty
      expect(visible_text).not_to include("Guess")
    end

    it "still has one when the Filing rule that fits is for an archived envelope, which is inactive" do
      filed("COSTCO #12", groceries)
      closed = create(:budget_envelope, budget: budget, name: "Closed")
      create(:budget_filing_rule, budget: budget, envelope: closed, text: "costco")
      closed.archive!
      row = unfiled("COSTCO #123", amount: -100)

      get new_bank_transaction_filing_path(row)

      expect(selected_envelope).to eq([ "Groceries" ])
      expect(visible_text).to include("Guess: like COSTCO #12 → Groceries")
    end

    it "never proposes an archived envelope, so history in one gives no Guess" do
      old = create(:budget_envelope, budget: budget, name: "Old groceries")
      filed("COSTCO #12", old)
      old.update!(archived_at: Time.current)
      row = unfiled("COSTCO #123", amount: -100)

      get new_bank_transaction_filing_path(row)

      expect(selected_envelope).to be_empty
      expect(visible_text).not_to include("Guess")
    end

    it "doesn't start a record added to split it on the Guess" do
      filed("COSTCO #12", groceries)
      row = unfiled("COSTCO #123", amount: -100)

      get new_bank_transaction_filing_path(row)

      assert_select "template select[name='filing[records][NEW_RECORD][envelope_id]'] option[selected]", count: 0
    end

    it "creates nothing, and changes nothing, by being shown" do
      filed("COSTCO #12", groceries)
      row = unfiled("COSTCO #123", amount: -100)

      expect { get new_bank_transaction_filing_path(row) }
        .not_to change { [ Budget::Spend.count, Budget::Refund.count, Budget::Deposit.count, Budget::SpendLink.count, Budget::FilingRule.count, row.reload.attributes ] }
      expect(row).to be_unfiled
    end

    it "runs the same number of queries however much the budget has filed" do
      filed("COSTCO #12", groceries)
      row = unfiled("COSTCO #123", amount: -100)
      get new_bank_transaction_filing_path(row)
      few = count_queries { get new_bank_transaction_filing_path(row) }

      20.times { |n| filed("MERCHANT #{n} #{n}", n.even? ? groceries : household) }
      create(:budget_filing_rule, budget: budget, envelope: household, text: "merchant")
      many = count_queries { get new_bank_transaction_filing_path(row) }

      expect(many).to eq(few)
    end
  end

  describe "filing something other than the Guess" do
    def file(bank_transaction, **record)
      post bank_transaction_filing_path(bank_transaction),
        params: { filing: { records: { "0" => { kind: "spend", envelope_id: groceries.id, description: "Costco", date: "2026-10-02", amount: "100", notes: "" }.merge(record) } } }
    end

    it "files what was sent, since the form starts on the Guess and no more, and the bank transaction isn't marked as guessed" do
      filed("COSTCO #12", groceries)
      row = unfiled("COSTCO #123", amount: -100)

      expect { file(row, envelope_id: household.id) }.to change(Budget::Spend, :count).by(1)

      expect(household.spends.sole).to have_attributes(amount: 100)
      expect(groceries.spends.count).to eq(1)
      expect(row.reload).to be_filed
      expect(row.filing_rule_id).to be_nil
    end

    it "comes back as it was sent when it's refused, without the Guess's label, which was only for where it started" do
      filed("COSTCO #12", groceries)
      row = unfiled("COSTCO #123", amount: -100)

      expect { file(row, envelope_id: household.id, amount: "60") }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(selected_envelope).to eq([ "Household" ])
      expect(Nokogiri::HTML(response.body).at("main").text).not_to include("Guess")
    end
  end
end
