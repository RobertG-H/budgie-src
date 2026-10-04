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

  # Saving the rule can also file the other unfiled bank transactions it fits, in the same request, so that a rule made after an Import
  # tidies that Import up too. They have to have gone the same way as this one, since an Ignore rule fits either.
  describe "sweeping the other unfiled bank transactions" do
    let!(:same_one) { create(:budget_bank_transaction, account: account, description: "COSTCO WHOLESALE #123", date: Date.new(2026, 9, 13), amount: -40) }
    let!(:another) { create(:budget_bank_transaction, account: account, description: "Costco Wholesale #123 Ottawa", date: Date.new(2026, 9, 14), amount: -60) }
    let!(:unrelated) { create(:budget_bank_transaction, account: account, description: "SHELL", amount: -30) }
    let!(:came_back) { create(:budget_bank_transaction, account: account, description: "COSTCO WHOLESALE #123", date: Date.new(2026, 9, 15), amount: 25) }
    let(:rule_params) { { make: "1", text: "costco wholesale #123", sweep: "1" } }

    describe "GET /bank_transactions/:bank_transaction_id/filing/new" do
      it "says how many other unfiled bank transactions the rule fits, with a second box ticked, to file or ignore them the same way" do
        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("2 other unfiled bank transactions fit.", "File or ignore them the same way now")
        assert_select "input[type=checkbox][name='filing[rule][sweep]'][value='1'][checked]"
        assert_select "input[type=hidden][name='filing[rule][sweep]'][value='0']"
        assert_select "turbo-frame#filing-rule-preview"
      end

      it "counts only the ones that went the same way, so money in isn't counted for a bank transaction that went out" do
        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("2 other unfiled bank transactions fit.")
        expect(visible_text).not_to include("3 other")
      end

      it "says one in the singular" do
        another.destroy!

        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("1 other unfiled bank transaction fits.")
      end

      it "says none fit, with no box to tick, when there aren't any" do
        [ same_one, another ].each(&:destroy!)

        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("No other unfiled bank transactions fit.")
        assert_select "input[name='filing[rule][sweep]']", count: 0
      end

      it "doesn't count a filed one or an ignored one" do
        same_one.ignore
        create(:budget_spend_link, bank_transaction: another)

        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("No other unfiled bank transactions fit.")
      end

      it "doesn't count a bank transaction that a more specific Filing rule fits, which is its rule's" do
        create(:budget_filing_rule, budget: budget, envelope: household, text: "costco wholesale #123 ottawa")

        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("1 other unfiled bank transaction fits.")
      end
    end

    describe "GET /bank_transactions/:bank_transaction_id/filing/rule, which the form asks for as the text is edited" do
      def preview(bank_transaction = money_out, **rule)
        get bank_transaction_rule_preview_path(bank_transaction), params: { filing: { rule: rule } }, headers: { "Turbo-Frame" => "filing-rule-preview" }
      end

      it "answers with the frame, and what the text as it stands would do, without the rest of the page" do
        preview(text: "costco", sweep: "1")

        expect(response).to have_http_status(:ok)
        assert_select "turbo-frame#filing-rule-preview"
        expect(response.body).to include("2 other unfiled bank transactions fit.")
        expect(response.body).not_to include("Sign out")
        expect(response.body).not_to include("Always file like this")
      end

      it "counts for the text it's given, so a shorter text that fits more shows it before the rule is made" do
        create(:budget_bank_transaction, account: account, description: "COSTCO GAS BAR", amount: -45)

        preview(text: "costco wholesale #123")
        expect(response.body).to include("2 other unfiled bank transactions fit.")

        preview(text: "costco")
        expect(response.body).to include("3 other unfiled bank transactions fit.")
      end

      it "keeps the box as it was ticked, or unticked" do
        preview(text: "costco", sweep: "0")
        assert_select "input[type=checkbox][name='filing[rule][sweep]']:not([checked])"

        preview(text: "costco", sweep: "1")
        assert_select "input[type=checkbox][name='filing[rule][sweep]'][checked]"
      end

      it "says nothing of a count for text that isn't one a rule can have: too short, or not in the bank's description" do
        preview(text: "co")
        expect(response.body).not_to include("unfiled bank transaction")

        preview(text: "loblaws")
        expect(response.body).not_to include("unfiled bank transaction")
      end

      it "says when the text is one that a rule already has, which it would update" do
        create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco")

        preview(text: "costco")

        expect(response.body).to include("Updates the Filing rule for 'costco', which files these as Spend from Groceries now.")
      end

      it "is not found for another user's bank transaction, and needs sign-in" do
        preview(create(:budget_bank_transaction), text: "shell")
        expect(response).to have_http_status(:not_found)

        delete session_path
        preview(text: "shell")
        expect(response).to redirect_to(sign_in_path)
      end
    end

    describe "POST /bank_transactions/:bank_transaction_id/filing, with the second box ticked" do
      it "files the other bank transactions the rule fits, the way the rule says, in the same request, with the rule noted on each" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: rule_params)

        expect(response).to redirect_to(unfiled_bank_transactions_path)
        follow_redirect!
        assert_select "[role=status]", text: "Bank transaction filed. The Filing rule also filed 2 other bank transactions."
        rule = budget.filing_rules.sole
        expect(groceries.spends.count).to eq(3)
        expect([ same_one.reload, another.reload ]).to all(be_filed)
        expect([ same_one.filing_rule_id, another.filing_rule_id ]).to eq([ rule.id, rule.id ])
        expect(money_out.reload.filing_rule_id).to be_nil
        expect([ unrelated.reload, came_back.reload ]).to all(be_unfiled)
      end

      it "files them as the bank gave them, with the whole amount, and not as this one was filed" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: rule_params, description: "Costco run")

        expect(same_one.reload.spend_links.sole.spend).to have_attributes(description: "COSTCO WHOLESALE #123", date: Date.new(2026, 9, 13), amount: 40, notes: "")
        expect(another.reload.spend_links.sole.spend.description).to eq("Costco Wholesale #123 Ottawa")
      end

      it "sweeps with the text as it was edited, which is how a rule that's too broad is trimmed or widened before it's made" do
        create(:budget_bank_transaction, account: account, description: "COSTCO GAS", amount: -45)

        post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "costco", sweep: "1" })

        expect(groceries.spends.count).to eq(4)
      end

      it "ignores the other bank transactions that went the same way for an Ignore rule, and leaves the other way alone" do
        post bank_transaction_ignore_path(money_out), params: file_params(rule: rule_params)

        follow_redirect!
        assert_select "[role=status]", text: "Bank transaction ignored. The Filing rule also ignored 2 other bank transactions."
        expect([ same_one.reload, another.reload ]).to all(be_ignored)
        expect(came_back.reload).to be_unfiled
        expect(budget.filing_rules.sole).to have_attributes(outcome: "ignore")
      end

      it "makes a Deposit rule sweep the money in that came the same way, which a Spend rule doesn't" do
        later_payroll = create(:budget_bank_transaction, account: account, description: "ACME PAYROLL", date: Date.new(2026, 10, 14), amount: 3100)

        post bank_transaction_filing_path(money_in), params: file_params(rule: { make: "1", text: "acme payroll", sweep: "1" }, kind: "deposit", date: "2026-09-30", amount: "3000", month: "2026-09-01")

        expect(later_payroll.reload.deposit_links.sole.deposit).to have_attributes(amount: 3100, month: Date.new(2026, 10, 1))
      end

      it "is one database transaction with the rule and the filing, so a failure in the sweep leaves all three undone" do
        allow_any_instance_of(Budget::FilingRule::Sweep).to receive(:run).and_raise(ActiveRecord::StatementInvalid, "the database went away")

        expect { post bank_transaction_filing_path(money_out), params: file_params(rule: rule_params) }.to raise_error(ActiveRecord::StatementInvalid)

        expect(Budget::FilingRule.count).to eq(0)
        expect(Budget::Spend.count).to eq(0)
        expect([ money_out.reload, same_one.reload, another.reload ]).to all(be_unfiled)
      end

      it "sweeps nothing for a split, which makes no rule" do
        split = { filing: { records: { "0" => record(amount: "60"), "1" => record(amount: "40", envelope_id: household.id) }, rule: rule_params } }

        post bank_transaction_filing_path(money_out), params: split

        expect([ same_one.reload, another.reload ]).to all(be_unfiled)
      end

      it "doesn't say anything more when nothing was swept" do
        [ same_one, another ].each(&:destroy!)

        post bank_transaction_filing_path(money_out), params: file_params(rule: rule_params)

        follow_redirect!
        assert_select "[role=status]", text: "Bank transaction filed."
      end
    end

    describe "POST /bank_transactions/:bank_transaction_id/filing, with the second box unticked" do
      it "makes the rule and files this one, and files no others, whether the box is unticked or isn't sent" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: rule_params.merge(sweep: "0"))

        expect(budget.filing_rules.count).to eq(1)
        expect([ same_one.reload, another.reload ]).to all(be_unfiled)

        post bank_transaction_filing_path(create(:budget_bank_transaction, account: account, description: "SHELL 2", amount: -5)), params: file_params(rule: { make: "1", text: "shell 2" })

        expect([ same_one.reload, another.reload ]).to all(be_unfiled)
      end
    end
  end
end
