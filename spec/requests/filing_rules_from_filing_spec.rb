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
    { filing: { records: { "0" => record(**attributes) }, rule: rule }.compact, from: "bank_transactions", filter: filter }
  end

  # The Bank transactions page the forms here are opened from, and where they go back to.
  let(:filter) { { state: "unfiled", date_from: "2026-09-01", date_to: "2026-09-30" } }
  let(:bank_transactions_page) { bank_transactions_path(filter: filter) }

  describe "GET /bank_transactions/:bank_transaction_id/filing/new" do
    it "offers 'Always file like this', ticked, with the bank's description as the text, without its number and symbols, to be edited right there" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "input[type=checkbox][name='filing[rule][make]'][value='1'][checked]"
      assert_select "input[type=hidden][name='filing[rule][make]'][value='0']"
      assert_select "label[for=filing_rule_make]", text: "Always file like this"
      assert_select "input[type=text][name='filing[rule][text]'][value='costco wholesale']"
      assert_select "label[for=filing_rule_text]", text: "Text to look for"
      expect(visible_text).to include("Capital letters, extra spaces, numbers and symbols like # and / are ignored. At least 3 characters.")
    end

    it "starts with text that passes its own check, however unusual the description's spaces and letters, since both are read the same way" do
      unusual = create(:budget_bank_transaction, account: account, description: "B\u00E4ckerei\u00A0Stra\u00DFe 12", amount: -9)

      get new_bank_transaction_filing_path(unusual)
      assert_select "input[name='filing[rule][text]'][value='b\u00E4ckerei strasse']"

      expect { post bank_transaction_filing_path(unusual), params: file_params(rule: { make: "1", text: "b\u00E4ckerei strasse 12" }, amount: "9") }
        .to change(budget.filing_rules, :count).by(1)
      expect(response).to redirect_to(bank_transactions_page)
    end

    it "has the Account to choose, its own or any, and no amount, which is for the Filing rules page" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "input[type=radio][name='filing[rule][account_id]']", count: 2
      assert_select "[name='filing[rule][amount]'], [name='filing[rule][outcome]'], [name='filing[rule][envelope_id]']", count: 0
    end

    it "offers it for money in too" do
      get new_bank_transaction_filing_path(money_in)

      assert_select "input[type=text][name='filing[rule][text]'][value='acme payroll']"
    end

    it "is left out, with a note saying why, when the description is under 3 characters" do
      short = create(:budget_bank_transaction, account: account, description: "  AB ", amount: -5)

      get new_bank_transaction_filing_path(short)

      assert_select "input[name^='filing[rule]']", count: 0
      expect(visible_text).to include("A Filing rule needs at least 3 characters in the bank transaction's description once numbers and symbols are ignored, so Always file like this isn't offered for this one.")
    end

    it "is left out too when the description is nothing but numbers and symbols, since there's no text to make a rule from" do
      only_an_id = create(:budget_bank_transaction, account: account, description: " 5551234567 / #12 ", amount: -5)

      get new_bank_transaction_filing_path(only_an_id)

      assert_select "input[name^='filing[rule]']", count: 0
      expect(visible_text).to include("once numbers and symbols are ignored, so Always file like this isn't offered for this one.")
    end

    it "starts without the numbers and symbols of the description, so the rule it makes fits the next one with another" do
      etransfer = create(:budget_bank_transaction, account: account, description: "Internet Banking E-TRANSFER 106121984683 James Graham-Hu", amount: 80)

      get new_bank_transaction_filing_path(etransfer)
      assert_select "input[type=text][name='filing[rule][text]'][value='internet banking e-transfer james graham-hu']"

      post bank_transaction_filing_path(etransfer), params: file_params(rule: { make: "1", text: "internet banking e-transfer james graham-hu" }, kind: "deposit", envelope_id: "", amount: "80")
      later = create(:budget_bank_transaction, account: account, description: "Internet Banking E-TRANSFER 999888777 James Graham-Hu", amount: 80).reload

      expect(budget.filing_rules.sole.text).to eq("internet banking e-transfer james graham-hu")
      expect(budget.filing_rules.sole.fits?(later)).to be(true)
    end

    it "keeps what's typed with a number in it as the text without it, which is what the rule is made with" do
      get new_bank_transaction_filing_path(money_out)

      post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "Costco Wholesale #4455" })

      expect(budget.filing_rules.sole.text).to eq("costco wholesale")
    end

    it "says when a Filing rule with that text exists for the Account, which it would update in place" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123", account: account)

      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).to include("Updates the Filing rule for 'costco wholesale' in Chequing, which files them as Spend from Groceries now.")
    end

    it "says it of an Ignore rule in its own words" do
      create(:budget_filing_rule, :ignore, budget: budget, text: "costco wholesale #123", account: account)

      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).to include("Updates the Filing rule for 'costco wholesale' in Chequing, which ignores them now.")
    end

    it "says nothing of another budget's rule, or of one for any Account, another Account or an amount, which are other rules" do
      create(:budget_filing_rule, text: "costco wholesale #123")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123", account: create(:budget_account, budget: budget, name: "Savings"))
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123", amount: -100, account: account)

      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).not_to include("Updates the Filing rule")
    end

    it "has the rule's inputs where the form can turn them off for a split, since a rule is never made from one" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "[data-filing-split-target=rule]"
    end
  end

  describe "POST /bank_transactions/:bank_transaction_id/filing, with the box ticked" do
    it "files the bank transaction and makes a Filing rule from what was done: the text, and the outcome with its envelope, for its own Account and with no amount" do
      expect { post bank_transaction_filing_path(money_out), params: file_params }.to change(Budget::FilingRule, :count).by(1).and change(Budget::Spend, :count).by(1)

      expect(response).to redirect_to(bank_transactions_page)
      follow_redirect!
      assert_select "[role=status]", text: "Bank transaction filed."
      expect(budget.filing_rules.sole).to have_attributes(text: "costco wholesale", outcome: "spend", envelope: groceries, account_id: account.id, amount: nil)
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
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123", account: account)

      expect { post bank_transaction_filing_path(money_out), params: file_params(envelope_id: household.id) }.not_to change(Budget::FilingRule, :count)

      expect(existing.reload).to have_attributes(outcome: "spend", envelope: household)
      expect(money_out.reload).to be_filed
    end

    it "turns an existing Spend rule into a Deposit rule, which takes its envelope away" do
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "acme payroll", account: account)

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
      assert_select "[role=alert]", text: /Text needs at least 3 characters once numbers and symbols are ignored/
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

    it "says so, and files nothing, when a rule with the same text was saved a moment ago, which only the unique index sees" do
      allow_any_instance_of(Budget::FilingRule).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

      expect { post bank_transaction_filing_path(money_out), params: file_params }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Another Filing rule with the same text, Account and amount was saved a moment ago. Try again./
      expect(money_out.reload).to be_unfiled
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
      expect(budget.filing_rules.sole).to have_attributes(text: "costco wholesale", outcome: "ignore", envelope_id: nil, account_id: account.id, amount: nil)
      expect(money_out.reload).to be_ignored
      expect(money_out.filing_rule_id).to be_nil
    end

    it "makes none when the box is unticked, or the form doesn't have it" do
      post bank_transaction_ignore_path(money_out), params: file_params(rule: { make: "0", text: "costco wholesale #123" })
      post bank_transaction_ignore_path(money_in), params: { from: "bank_transactions", filter: filter }

      expect(Budget::FilingRule.count).to eq(0)
      expect([ money_out.reload, money_in.reload ]).to all(be_ignored)
    end

    it "updates an existing rule with identical conditions to Ignore, in place" do
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123", account: account)

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
      assert_select "[role=alert]", text: /Text needs at least 3 characters once numbers and symbols are ignored/
      assert_select "h1", text: "File bank transaction"
      assert_select "input[name='filing[records][0][description]'][value='Costco run']"
      expect(money_out.reload).to be_unfiled
    end

    it "still says a bank transaction that's filed can't be ignored, and makes no rule" do
      post bank_transaction_filing_path(money_out), params: file_params(rule: nil)

      expect { post bank_transaction_ignore_path(money_out), params: file_params }.not_to change(Budget::FilingRule, :count)

      expect(response).to redirect_to(bank_transactions_page)
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

      it "doesn't count a bank transaction that a more specific Filing rule fits, which is its rule's, and says so" do
        create(:budget_filing_rule, budget: budget, envelope: household, text: "costco wholesale #123 ottawa", account: account)

        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("1 other unfiled bank transaction fits.", "1 more fits, but a more specific Filing rule files it.")
      end

      it "says so even when there's nothing else left to file, with no box to tick" do
        # An exact amount is more specific than anything else, so each of these is the one to file the bank transaction it fits.
        create(:budget_filing_rule, budget: budget, envelope: household, text: "costco", amount: -40)
        create(:budget_filing_rule, budget: budget, envelope: household, text: "costco", amount: -60)

        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("2 other unfiled bank transactions fit, but a more specific Filing rule files them.")
        assert_select "input[name='filing[rule][sweep]']", count: 0
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

      it "carries the text as the rule keeps it, hidden, for the sentence under Always file like this, so the server is the only one that cleans it" do
        preview(text: "  COSTCO  WHOLESALE #4455 / ")

        assert_select "turbo-frame#filing-rule-preview[data-action='turbo:frame-load->sweep-preview#showCleanedText']"
        assert_select "turbo-frame#filing-rule-preview span[hidden][data-sweep-preview-target=cleaned]", text: "costco wholesale"
      end

      it "keeps the box as it was ticked, or unticked" do
        preview(text: "costco", sweep: "0")
        assert_select "input[type=checkbox][name='filing[rule][sweep]']:not([checked])"

        preview(text: "costco", sweep: "1")
        assert_select "input[type=checkbox][name='filing[rule][sweep]'][checked]"
      end

      it "says nothing of a count for text that isn't one a rule can have: too short, or not in the bank's description, and says why" do
        [ "co", "loblaws" ].each do |text|
          preview(text: text)

          expect(response.body).not_to include("unfiled bank transaction")
          expect(response.body).to include("The text has to be at least 3 characters once numbers and symbols are ignored, and part of this bank transaction's description.")
        end
      end

      it "says when the text is one that a rule already has, which it would update" do
        create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco", account: account)

        preview(text: "costco")

        expect(response.body).to include("Updates the Filing rule for 'costco' in Chequing, which files them as Spend from Groceries now.")
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

        expect(response).to redirect_to(bank_transactions_page)
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

  # "Always file like this" is for the bank transaction's own Account unless the person chooses any, which is what a rule usually should be.
  describe "the Account the rule is for" do
    let!(:savings) { create(:budget_account, budget: budget, name: "Savings") }
    let!(:here) { create(:budget_bank_transaction, account: account, description: "COSTCO WHOLESALE #123", date: Date.new(2026, 9, 13), amount: -40) }
    let!(:there) { create(:budget_bank_transaction, account: savings, description: "COSTCO WHOLESALE #123", date: Date.new(2026, 9, 14), amount: -60) }

    def radios
      css_select("input[type=radio][name='filing[rule][account_id]']")
    end

    def preview(**rule)
      get bank_transaction_rule_preview_path(money_out), params: { filing: { rule: { text: "costco wholesale #123" }.merge(rule) } }, headers: { "Turbo-Frame" => "filing-rule-preview" }
    end

    describe "GET /bank_transactions/:bank_transaction_id/filing/new" do
      it "has two radio buttons in Edit rule: only in the bank transaction's own Account, chosen to start with, and any account" do
        get new_bank_transaction_filing_path(money_out)

        expect(radios.map { |radio| [ radio["value"], radio.key?("checked") ] }).to eq([ [ account.id.to_s, true ], [ "", false ] ])
        edit_rule = css_select("details").find { |details| details.at("summary").text.squish == "Edit rule" }
        expect(edit_rule.css("input[type=radio][name='filing[rule][account_id]']").size).to eq(2)
        expect(edit_rule.at("fieldset legend").text).to eq("Account")
        expect(edit_rule.css("label").map { |label| label.text.squish }).to include("Only in Chequing", "Any account")
      end

      it "is not a select of every Account, since a rule for another Account wouldn't fit the bank transaction it's made from" do
        get new_bank_transaction_filing_path(money_out)

        assert_select "select[name='filing[rule][account_id]']", count: 0
        expect(response.body).not_to include("Savings")
      end

      it "says in the sentence which Account it's for: its own to start with, and any when that's the one sent" do
        get new_bank_transaction_filing_path(money_out)

        pinned, anywhere = css_select("[data-sweep-preview-target=variant]")
        expect(pinned.text.squish).to eq("Chequing bank transactions with 'costco wholesale' in their description are filed the same way as they come in.")
        expect(pinned.key?("hidden")).to be(false)
        expect(anywhere.text.squish).to eq("Bank transactions in any account with 'costco wholesale' in their description are filed the same way as they come in.")
        expect(anywhere.key?("hidden")).to be(true)
      end

      it "counts only the Account's own unfiled bank transactions that the rule fits, which is what's swept" do
        get new_bank_transaction_filing_path(money_out)

        expect(visible_text).to include("1 other unfiled bank transaction fits.")
      end

      it "sends the choice with the radios inside the form's rule fields, so the preview already has it" do
        get new_bank_transaction_filing_path(money_out)

        assert_select "[data-controller~=sweep-preview][data-sweep-preview-scope-value='filing[rule]'] input[type=radio][name='filing[rule][account_id]'][data-action='input->sweep-preview#update']", count: 2
      end
    end

    describe "POST /bank_transactions/:bank_transaction_id/filing" do
      it "makes a rule for the bank transaction's Account when it's chosen, and sweeps only that Account's bank transactions" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "costco wholesale #123", account_id: account.id.to_s, sweep: "1" })

        expect(budget.filing_rules.sole).to have_attributes(text: "costco wholesale", account_id: account.id, amount: nil)
        expect(here.reload).to be_filed
        expect(there.reload).to be_unfiled
        follow_redirect!
        assert_select "[role=status]", text: "Bank transaction filed. The Filing rule also filed 1 other bank transaction."
      end

      it "makes a rule for any Account when that's chosen, and sweeps every Account's" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "costco wholesale #123", account_id: "", sweep: "1" })

        expect(budget.filing_rules.sole).to have_attributes(text: "costco wholesale", account_id: nil)
        expect([ here.reload, there.reload ]).to all(be_filed)
        follow_redirect!
        assert_select "[role=status]", text: "Bank transaction filed. The Filing rule also filed 2 other bank transactions."
      end

      it "makes the rule for the bank transaction's own Account, whatever other Account's id is sent, since the rule has to fit it" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "costco wholesale #123", account_id: savings.id.to_s })

        expect(budget.filing_rules.sole.account_id).to eq(account.id)
      end

      it "makes a rule for the Account when the form doesn't say, as it starts" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "costco wholesale #123" })

        expect(budget.filing_rules.sole.account_id).to eq(account.id)
      end

      it "makes a different rule for a pinned and an any-account rule with the same text, and updates the one with the same Account in place" do
        anywhere = create(:budget_filing_rule, budget: budget, envelope: household, text: "costco wholesale #123")

        expect { post bank_transaction_filing_path(money_out), params: file_params }.to change(Budget::FilingRule, :count).by(1)

        expect(anywhere.reload).to have_attributes(envelope: household, account_id: nil)
        pinned = budget.filing_rules.where.not(id: anywhere.id).sole
        expect(pinned).to have_attributes(envelope: groceries, account_id: account.id)

        expect { post bank_transaction_filing_path(money_in), params: file_params(rule: { make: "1", text: "acme payroll" }, kind: "deposit", date: "2026-09-30", amount: "3000") }
          .to change(Budget::FilingRule, :count).by(1)
      end

      it "makes the rule for the Account from Ignore too" do
        post bank_transaction_ignore_path(money_out), params: file_params(rule: { make: "1", text: "costco wholesale #123", account_id: account.id.to_s })

        expect(budget.filing_rules.sole).to have_attributes(outcome: "ignore", account_id: account.id)
      end

      it "comes back with the choice it was sent when it's refused, and the sentence for it" do
        post bank_transaction_filing_path(money_out), params: file_params(rule: { make: "1", text: "costco wholesale #123", account_id: "" }, envelope_id: "")

        expect(response).to have_http_status(:unprocessable_content)
        expect(radios.map { |radio| [ radio["value"], radio.key?("checked") ] }).to eq([ [ account.id.to_s, false ], [ "", true ] ])
        pinned, anywhere = css_select("[data-sweep-preview-target=variant]")
        expect(pinned.key?("hidden")).to be(true)
        expect(anywhere.key?("hidden")).to be(false)
      end
    end

    describe "GET /bank_transactions/:bank_transaction_id/filing/rule" do
      it "counts for the Account as it's chosen" do
        preview(account_id: account.id.to_s)
        expect(response.body).to include("1 other unfiled bank transaction fits.")

        preview(account_id: "")
        expect(response.body).to include("2 other unfiled bank transactions fit.")
      end

      it "counts for the Account by default, when the choice isn't sent" do
        preview

        expect(response.body).to include("1 other unfiled bank transaction fits.")
      end

      it "says which Account's rule it would update, and only that one's" do
        create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco wholesale #123")
        create(:budget_filing_rule, budget: budget, envelope: household, text: "costco wholesale #123", account: account)

        preview(account_id: account.id.to_s)
        expect(response.body).to include("Updates the Filing rule for 'costco wholesale' in Chequing, which files them as Spend from Household now.")

        preview(account_id: "")
        expect(response.body).to include("Updates the Filing rule for 'costco wholesale', which files them as Spend from Groceries now.")
        expect(response.body).not_to include("in Chequing")
      end
    end
  end
end
