require "rails_helper"

# "Always file like this" on the filing form makes a Filing rule from what a person does, in the same database transaction as the
# filing or the ignoring, so that the next Import does it by itself (ADR 0012).
RSpec.describe "Filing rules from the filing form", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }
  let!(:money_out) { create(:budget_bank_transaction, account: account, description: "COSTCO  WHOLESALE #123", date: Date.new(2026, 9, 12), amount: -100) }
  let!(:money_in) { create(:budget_bank_transaction, account: account, description: "ACME PAYROLL", date: Date.new(2026, 9, 30), amount: 3000) }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  def record(**attributes)
    { kind: "spend", envelope_id: groceries.id, description: "Costco run", date: "2026-09-12", amount: "100" }.merge(attributes)
  end

  # What the form sends: its records, and what "Always file like this" has, which is nothing at all for a form that doesn't offer it.
  def file_params(rule: { make: "1", text: "costco wholesale #123" }, **attributes)
    { filing: { records: { "0" => record(**attributes) }, rule: rule }.compact, from: "unfiled" }
  end

  describe "GET /bank_transactions/:bank_transaction_id/filing/new" do
    it "offers 'Always file like this', ticked, with the bank's description as the text, normalised, to be edited right there" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "input[type=checkbox][name='filing[rule][make]'][value='1'][checked]"
      assert_select "input[type=hidden][name='filing[rule][make]'][value='0']"
      assert_select "label[for=filing_rule_make]", text: "Always file like this"
      assert_select "input[type=text][name='filing[rule][text]'][value='costco wholesale #123']"
      assert_select "label[for=filing_rule_text]", text: "Text to look for"
      expect(visible_text).to include("Capital letters and extra spaces don't matter. At least 3 characters.")
    end

    it "has no Account or amount to choose, which is for the Filing rules page" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "[name^='filing[rule]']", count: 3
      assert_select "[name='filing[rule][account_id]'], [name='filing[rule][amount]'], [name='filing[rule][outcome]'], [name='filing[rule][envelope_id]']", count: 0
    end

    it "offers it for money in too" do
      get new_bank_transaction_filing_path(money_in)

      assert_select "input[type=text][name='filing[rule][text]'][value='acme payroll']"
    end

    it "is left out, with a note saying why, when the description is under 3 characters" do
      short = create(:budget_bank_transaction, account: account, description: "  AB ", amount: -5)

      get new_bank_transaction_filing_path(short)

      assert_select "input[name^='filing[rule]']", count: 0
      expect(visible_text).to include("A Filing rule needs at least 3 characters in the bank transaction's description, so Always file like this isn't offered for this one.")
    end

    it "says when a Filing rule with that text exists, which it would update in place" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123")

      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).to include("Updates the Filing rule for 'costco wholesale #123', which files these as Spend from Groceries now.")
    end

    it "says it of an Ignore rule in its own words" do
      create(:budget_filing_rule, :ignore, budget: budget, text: "costco wholesale #123")

      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).to include("Updates the Filing rule for 'costco wholesale #123', which ignores these now.")
    end

    it "says nothing of another budget's rule, or of one with an Account or amount condition, which are other rules" do
      create(:budget_filing_rule, text: "costco wholesale #123")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123", account: account)
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123", amount: -100)

      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).not_to include("Updates the Filing rule")
    end

    it "has the rule's inputs where the form can turn them off for a split, since a rule is never made from one" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "[data-filing-split-target=rule]"
    end
  end

  describe "POST /bank_transactions/:bank_transaction_id/filing, with the box ticked" do
    it "files the bank transaction and makes a Filing rule from what was done: the text, and the outcome with its envelope, and no Account or amount" do
      expect { post bank_transaction_filing_path(money_out), params: file_params }.to change(Budget::FilingRule, :count).by(1).and change(Budget::Spend, :count).by(1)

      expect(response).to redirect_to(unfiled_bank_transactions_path)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed."
      expect(budget.filing_rules.sole).to have_attributes(text: "costco wholesale #123", outcome: "spend", envelope: groceries, account_id: nil, amount: nil)
    end

    it "takes the text as it was edited, normalised" do
      post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "  COSTCO   Wholesale " })

      expect(budget.filing_rules.sole.text).to eq("costco wholesale")
    end

    it "doesn't record the rule on the bank transaction it was made from, which a person filed" do
      post bank_transaction_filing_path(money_out), params: file_params

      expect(money_out.reload).to be_filed
      expect(money_out.filing_rule_id).to be_nil
    end

    it "makes a Deposit rule from a Deposit, which has no envelope, and a Refund rule from a Refund" do
      post bank_transaction_filing_path(money_in), params: file_params(rule: { make: "1", text: "acme payroll" }, kind: "deposit", envelope_id: groceries.id, date: "2026-09-30", amount: "3000", month: "2026-10-01")
      refund_in = create(:budget_bank_transaction, account: account, description: "LOBLAWS RETURN", amount: 20)
      post bank_transaction_filing_path(refund_in), params: file_params(rule: { make: "1", text: "loblaws return" }, kind: "refund", amount: "20")

      expect(budget.filing_rules.find_by!(text: "acme payroll")).to have_attributes(outcome: "deposit", envelope_id: nil)
      expect(budget.filing_rules.find_by!(text: "loblaws return")).to have_attributes(outcome: "refund", envelope: groceries)
    end

    it "makes a rule that files a Deposit with its date's month, even when this one was filed for the month after" do
      post bank_transaction_filing_path(money_in), params: file_params(rule: { make: "1", text: "acme payroll" }, kind: "deposit", date: "2026-09-30", amount: "3000", month: "2026-10-01")
      expect(budget.deposits.sole.month).to eq(Date.new(2026, 10, 1))

      later = create(:budget_bank_transaction, account: account, description: "ACME PAYROLL", date: Date.new(2026, 10, 14), amount: 3000)
      Budget::FilingRule::Applier.new(budget).apply([ later.reload ])

      expect(later.reload.deposit_links.sole.deposit).to have_attributes(date: Date.new(2026, 10, 14), month: Date.new(2026, 10, 1))
    end

    it "updates the rule with identical conditions in place, instead of making another" do
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123")

      expect { post bank_transaction_filing_path(money_out), params: file_params(envelope_id: household.id) }.not_to change(Budget::FilingRule, :count)

      expect(existing.reload).to have_attributes(outcome: "spend", envelope: household)
      expect(money_out.reload).to be_filed
    end

    it "turns an existing Spend rule into a Deposit rule, which takes its envelope away" do
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "acme payroll")

      post bank_transaction_filing_path(money_in), params: file_params(rule: { make: "1", text: "acme payroll" }, kind: "deposit", date: "2026-09-30", amount: "3000", month: "2026-09-01")

      expect(existing.reload).to have_attributes(outcome: "deposit", envelope_id: nil)
    end

    it "makes no rule for a split, which is more than one record, though the box was ticked" do
      split = { filing: { records: { "0" => record(amount: "60"), "1" => record(amount: "40", envelope_id: household.id) }, rule: { make: "1", text: "costco wholesale #123" } } }

      expect { post bank_transaction_filing_path(money_out), params: split }.to change(Budget::Spend, :count).by(2)

      expect(Budget::FilingRule.count).to eq(0)
    end

    it "is one database transaction with the filing: a rule that's refused files nothing, and says what's wrong, with the form as it was" do
      expect { post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "co" }) }
        .to not_change(Budget::Spend, :count).and not_change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Text is too short \(minimum is 3 characters\)/
      assert_select "input[name='filing[rule][text]'][value=co]"
      assert_select "input[name='filing[records][0][description]'][value='Costco run']"
      expect(money_out.reload).to be_unfiled
    end

    it "is refused when the text isn't part of the bank's description, since the rule wouldn't fit this bank transaction" do
      expect { post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "loblaws" }) }
        .to not_change(Budget::Spend, :count).and not_change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Text must be part of the bank transaction's description/
    end

    it "makes no rule when the filing is refused, which says why, as it does without a rule" do
      expect { post bank_transaction_filing_path(money_out), params: file_params(amount: "60") }.not_to change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /The records add up to \$60.00, which is \$40.00 less/
    end

    it "makes no rule for an envelope that isn't the budget's, which can't be filed into" do
      expect { post bank_transaction_filing_path(money_out), params: file_params(envelope_id: create(:budget_envelope).id) }.not_to change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "files nothing when saving the rule fails, so a failure leaves neither" do
      allow_any_instance_of(Budget::FilingRule).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, "the database went away")

      expect { post bank_transaction_filing_path(money_out), params: file_params }.to raise_error(ActiveRecord::StatementInvalid)

      expect(Budget::Spend.count).to eq(0)
      expect(Budget::SpendLink.count).to eq(0)
      expect(money_out.reload).to be_unfiled
    end
  end

  describe "POST /bank_transactions/:bank_transaction_id/filing, with the box unticked" do
    it "makes no rule, however the form says it, and files as it always has" do
      [ { make: "0", text: "costco wholesale #123" }, { text: "costco wholesale #123" }, nil ].each_with_index do |rule, index|
        bank_transaction = index.zero? ? money_out : create(:budget_bank_transaction, account: account, description: "COSTCO #{index}", amount: -100)

        post bank_transaction_filing_path(bank_transaction), params: file_params(rule: rule)

        expect(bank_transaction.reload).to be_filed
      end

      expect(Budget::FilingRule.count).to eq(0)
    end

    it "doesn't touch a rule that's there, even for the same text" do
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123")

      post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "0", text: "costco wholesale #123" }, envelope_id: household.id)

      expect(existing.reload.envelope).to eq(groceries)
    end
  end

  describe "POST /bank_transactions/:bank_transaction_id/ignore, with the box ticked" do
    it "ignores the bank transaction and makes an Ignore rule from the text, with no envelope, which fits money in or out" do
      expect { post bank_transaction_ignore_path(money_out), params: file_params.merge(from: "account") }.to change(Budget::FilingRule, :count).by(1)

      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction ignored."
      expect(budget.filing_rules.sole).to have_attributes(text: "costco wholesale #123", outcome: "ignore", envelope_id: nil, account_id: nil, amount: nil)
      expect(money_out.reload).to be_ignored
      expect(money_out.filing_rule_id).to be_nil
    end

    it "makes none when the box is unticked, or the form doesn't have it" do
      post bank_transaction_ignore_path(money_out), params: file_params(rule: { make: "0", text: "costco wholesale #123" })
      post bank_transaction_ignore_path(money_in), params: { from: "unfiled" }

      expect(Budget::FilingRule.count).to eq(0)
      expect([ money_out.reload, money_in.reload ]).to all(be_ignored)
    end

    it "updates an existing rule with identical conditions to Ignore, in place" do
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123")

      expect { post bank_transaction_ignore_path(money_out), params: file_params }.not_to change(Budget::FilingRule, :count)

      expect(existing.reload).to have_attributes(outcome: "ignore", envelope_id: nil)
    end

    it "makes no rule from a form with a split in it, which Ignore doesn't read" do
      split = { filing: { records: { "0" => record(amount: "60"), "1" => record(amount: "40") }, rule: { make: "1", text: "costco wholesale #123" } } }

      post bank_transaction_ignore_path(money_out), params: split

      expect(money_out.reload).to be_ignored
      expect(Budget::FilingRule.count).to eq(0)
    end

    it "is refused with the filing form again when the rule is, ignoring nothing, and the form is as it was" do
      expect { post bank_transaction_ignore_path(money_out), params: file_params(rule: { make: "1", text: "co" }) }.not_to change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Text is too short/
      assert_select "h1", text: "File bank transaction"
      assert_select "input[name='filing[records][0][description]'][value='Costco run']"
      expect(money_out.reload).to be_unfiled
    end

    it "still says a bank transaction that's filed can't be ignored, and makes no rule" do
      post bank_transaction_filing_path(money_out), params: file_params(rule: nil)

      expect { post bank_transaction_ignore_path(money_out), params: file_params }.not_to change(Budget::FilingRule, :count)

      expect(response).to redirect_to(unfiled_bank_transactions_path)
      follow_redirect!
      assert_select "[role=alert]", text: "This bank transaction is filed. Un-file it before ignoring it."
    end
  end
end
