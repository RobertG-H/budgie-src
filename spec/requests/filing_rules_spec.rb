require "rails_helper"

# The Filing rules page: every rule in one place, grouped by what it sets, where a person can see and change everything that gets filed
# automatically, and make a rule before the first Import. Editing or deleting a rule never changes what it already filed or ignored.
RSpec.describe "Filing rules", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:dining) { create(:budget_envelope, budget: budget, name: "Eating out") }
  let(:others_rule) { create(:budget_filing_rule, text: "someone else's") }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  def rule_params(**attributes)
    { filing_rule: { text: "loblaws", account_id: "", amount: "", outcome: "spend", envelope_id: groceries.id }.merge(attributes) }
  end

  # What a picker offers, as one line of text per option.
  def choices(name)
    css_select("select[name='filing_rule[#{name}]'] option").map { |option| option.text.strip }
  end

  describe "GET /filing_rules" do
    # What a table says, a row at a time, as the text of its cells: Text, Does, Account, Amount, Filed count and the actions.
    def tables
      css_select("main section").map { |section| section.css("tbody tr").map { |row| row.css("th, td").map { |cell| cell.text.squish } } }
    end

    it "lists every rule grouped by what it sets, a table for each: one section per envelope alphabetically, then Deposit, then Ignore" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco", account: chequing)
      create(:budget_filing_rule, :refund, budget: budget, envelope: groceries, text: "loblaws return")
      create(:budget_filing_rule, budget: budget, envelope: dining, text: "pizza nova", amount: -25)
      create(:budget_filing_rule, :deposit, budget: budget, text: "acme payroll")
      create(:budget_filing_rule, :ignore, budget: budget, text: "payment thank you")

      get filing_rules_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Filing rules · Budgie"
      assert_select "h1", text: "Filing rules"
      expect(css_select("main h2").map { |heading| heading.text.squish }).to eq([ "Eating out", "Groceries", "Deposit", "Ignore" ])
      expect(tables).to eq([
        [ [ "pizza nova", "Spend", "Any account", "-$25.00", "0", "Edit Delete" ] ],
        [ [ "costco", "Spend", "Chequing", "Any amount", "0", "Edit Delete" ],
          [ "loblaws", "Spend", "Any account", "Any amount", "0", "Edit Delete" ],
          [ "loblaws return", "Refund", "Any account", "Any amount", "0", "Edit Delete" ] ],
        [ [ "acme payroll", "Deposit", "Any account", "Any amount", "0", "Edit Delete" ] ],
        [ [ "payment thank you", "Ignore", "Any account", "Any amount", "0", "Edit Delete" ] ]
      ])
    end

    it "leaves out a section that has no rules, and shows every rule of an envelope under its name, 'Everything that goes to Groceries'" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      get filing_rules_path

      expect(css_select("main h2").map { |heading| heading.text.squish }).to eq([ "Groceries" ])
    end

    it "has a table for each section, with the columns in their order, a caption that names it, and an Actions column that has no visible heading" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      create(:budget_filing_rule, :ignore, budget: budget, text: "payment thank you")

      get filing_rules_path

      assert_select "main section", count: 2
      assert_select "main section table.table.table-sm", count: 2
      expect(css_select("main section table caption.sr-only").map(&:text)).to eq([ "Groceries", "Ignore" ])
      headings = css_select("main section:first-of-type thead th")
      expect(headings.map { |heading| heading.text.squish }).to eq([ "Text", "Does", "Account", "Amount", "Filed count", "Actions" ])
      expect(headings.last.at("span.sr-only").text).to eq("Actions")
      expect(headings.map { |heading| heading["scope"] }.uniq).to eq([ "col" ])
    end

    it "scrolls each table sideways in its own wrapper, and never the page, and keeps the Text, which links to the edit page, as the first column" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      get filing_rules_path

      assert_select "main section > div.overflow-x-auto.rounded-box.border.border-base-300 > table.table"
      assert_select "main section thead th:first-child", text: "Text"
    end

    it "says the figures in the cells: the amount signed and red when it's money out, right-aligned with the filed count, and muted when there's none" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", amount: -82.45, account: chequing)
      create(:budget_filing_rule, :refund, budget: budget, envelope: groceries, text: "loblaws return")

      get filing_rules_path

      priced, plain = css_select("main tbody tr")
      expect(priced.css("td")[2].text.squish).to eq("-$82.45")
      expect(priced.css("td")[2]["class"]).to include("text-right", "tabular-nums")
      expect(priced.css("td")[2].at("span.text-error").text).to eq("-$82.45")
      expect(priced.css("td")[3]["class"]).to include("text-right", "tabular-nums")
      expect(plain.css("td")[1].at("span")["class"]).to include("text-base-content/70")
      expect(plain.css("td")[2].at("span")["class"]).to include("text-base-content/70")
      expect(plain.css("td")[2].text.squish).to eq("Any amount")
    end

    it "has the Text as the only link but the Edit button, which both go to where it's edited" do
      rule = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      get filing_rules_path

      assert_select "main tbody tr th a.link[href='#{edit_filing_rule_path(rule)}']", text: "loblaws"
      assert_select "main tbody tr td a.btn.btn-ghost.btn-sm[href='#{edit_filing_rule_path(rule)}']", text: "Edit"
      expect(css_select("main tbody a").size).to eq(2)
      assert_select "main li", count: 0
    end

    it "has a Delete button in the row that asks first, naming the rule, and then deletes it" do
      rule = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      get filing_rules_path

      assert_select "main tbody tr td form[action='#{filing_rule_path(rule)}'][method=post][data-turbo-confirm]" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "button.btn.btn-ghost.btn-sm.text-error", text: "Delete"
      end
      expect(css_select("main tbody form button, main tbody a").size).to eq(3)
    end

    it "asks 'Delete the Filing rule for 'loblaws'?' and says what stays, with the row's own count: none, one, or several" do
      none = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco")
      one = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      many = create(:budget_filing_rule, :ignore, budget: budget, text: "payment thank you")
      account = create(:budget_account, budget: budget)
      create(:budget_bank_transaction, :filed, account: account).update_columns(filing_rule_id: one.id)
      3.times { create(:budget_bank_transaction, :ignored, account: account).update_columns(filing_rule_id: many.id) }

      get filing_rules_path

      question = ->(rule) { css_select("form[action='#{filing_rule_path(rule)}']").first["data-turbo-confirm"] }
      expect(question.(none)).to eq("Delete the Filing rule for 'costco'?")
      expect(question.(one)).to eq("Delete the Filing rule for 'loblaws'? The bank transaction it filed or ignored stays as it is.")
      expect(question.(many)).to eq("Delete the Filing rule for 'payment thank you'? The 3 bank transactions it filed or ignored stay as they are.")
    end

    it "escapes the text in the question and in the row, since it's whatever someone typed" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "<b>bold</b> 'quote'")

      get filing_rules_path

      assert_select "main b", count: 0
      expect(css_select("main form[data-turbo-confirm]").first["data-turbo-confirm"]).to eq("Delete the Filing rule for '<b>bold</b> 'quote''?")
    end

    it "says how many bank transactions each rule filed or ignored in the Filed count, counting only the ones that still are" do
      loblaws = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      payment = create(:budget_filing_rule, :ignore, budget: budget, text: "payment thank you")
      account = create(:budget_account, budget: budget)
      2.times { create(:budget_bank_transaction, :filed, account: account).update_columns(filing_rule_id: loblaws.id) }
      create(:budget_bank_transaction, account: account).update_columns(filing_rule_id: loblaws.id) # un-filed since, so it isn't counted
      create(:budget_bank_transaction, :ignored, account: account).update_columns(filing_rule_id: payment.id)

      get filing_rules_path

      expect(tables).to eq([
        [ [ "loblaws", "Spend", "Any account", "Any amount", "2", "Edit Delete" ] ],
        [ [ "payment thank you", "Ignore", "Any account", "Any amount", "1", "Edit Delete" ] ]
      ])
      expect(visible_text).to include("Filed count is how many bank transactions a rule filed or ignored that still are.")
    end

    it "marks a rule on an archived envelope Inactive in words, once under the section's heading, and with a badge in each of its rows" do
      envelope = create(:budget_envelope, budget: budget, name: "Old gym")
      create(:budget_filing_rule, budget: budget, envelope: envelope, text: "gym membership")
      create(:budget_filing_rule, :refund, budget: budget, envelope: envelope, text: "gym refund")
      envelope.archive!
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      get filing_rules_path

      expect(css_select("main h2").map { |heading| heading.text.squish }).to eq([ "Groceries", "Old gym Archived" ])
      old_gym = css_select("main section").last
      expect(old_gym.text.scan("Inactive while its envelope is archived.").size).to eq(1)
      expect(old_gym.at("h2").next_element.text.squish).to eq("Inactive while its envelope is archived.")
      expect(old_gym.css("tbody tr").map { |row| row.at("th").text.squish }).to eq([ "gym membership Inactive", "gym refund Inactive" ])
      expect(old_gym.css("tbody tr th .badge").map(&:text)).to eq([ "Inactive", "Inactive" ])
      expect(css_select("main section").first.text).not_to include("Inactive")
    end

    it "no longer says the long sentence of what a rule does in each row" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      get filing_rules_path

      expect(visible_text).not_to include("filed or ignored yet")
      expect(visible_text).not_to include("Spend from Groceries")
    end

    it "refreshes the page in place when it's sent back to itself, keeping the scroll, so a delete leaves a person where they were" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      get filing_rules_path

      assert_select "meta[name='turbo-refresh-method'][content=morph]"
      assert_select "meta[name='turbo-refresh-scroll'][content=preserve]"
    end

    it "says there are none, with a way to make one" do
      get filing_rules_path

      expect(visible_text).to include("You don't have any Filing rules yet.")
      assert_select "main a.btn[href='#{new_filing_rule_path}']", text: "New Filing rule"
    end

    it "has a link to it in the header's sections, which is the current one there" do
      get filing_rules_path

      assert_select "nav[aria-label=Sections] a[href='#{filing_rules_path}'][aria-current=page]", text: "Filing rules"
      get bank_transactions_path
      assert_select "nav[aria-label=Sections] a[href='#{filing_rules_path}']:not([aria-current])", text: "Filing rules"
    end

    it "doesn't list another budget's rules" do
      others_rule

      get filing_rules_path

      expect(response.body).not_to include("someone else&#39;s")
      expect(visible_text).to include("You don't have any Filing rules yet.")
    end

    it "runs the same number of queries however many rules there are, the counts included" do
      envelope = create(:budget_envelope, budget: budget, name: "Household")
      create(:budget_filing_rule, budget: budget, envelope: envelope, text: "loblaws", account: chequing)
      get filing_rules_path
      few = count_queries { get filing_rules_path }

      10.times do |n|
        other = create(:budget_envelope, budget: budget, name: "Extra #{n}")
        rule = create(:budget_filing_rule, budget: budget, envelope: other, text: "merchant #{n}", account: chequing)
        create(:budget_bank_transaction, :filed, account: chequing).update_columns(filing_rule_id: rule.id)
      end
      create(:budget_filing_rule, :ignore, budget: budget, text: "interest")
      many = count_queries { get filing_rules_path }

      expect(many).to eq(few)
    end

    it "requires sign-in" do
      delete session_path

      get filing_rules_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "GET /filing_rules/new" do
    it "has a form for the text, the Account, the amount, what to do and the envelope" do
      get new_filing_rule_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "New Filing rule · Budgie"
      assert_select "h1", text: "New Filing rule"
      assert_select "form[action='#{filing_rules_path}'][method=post]" do
        assert_select "input[type=text][name='filing_rule[text]']"
        assert_select "select[name='filing_rule[account_id]']"
        assert_select "input[type=number][name='filing_rule[amount]'][step='0.01']"
        assert_select "input[type=radio][name='filing_rule[outcome]']", count: 4
        assert_select "select[name='filing_rule[envelope_id]']"
        assert_select "input[type=submit][value='Create Filing rule']"
      end
      assert_select "a.btn[href='#{filing_rules_path}']", text: "Cancel"
      expect(visible_text).to include("Spend", "Refund", "Deposit", "Ignore", "How to file them")
    end

    it "offers the budget's Accounts, with Any account first, and its envelopes in use, and no one else's or archived ones" do
      create(:budget_account, budget: budget, name: "Savings")
      create(:budget_account, name: "Someone else's")
      create(:budget_envelope, budget: budget, name: "Old", archived_at: Time.current)
      create(:budget_envelope, name: "Someone else's envelope")

      get new_filing_rule_path

      expect(choices("account_id")).to eq([ "Any account", "Chequing", "Savings" ])
      expect(choices("envelope_id")).to eq([ "Choose an envelope", "Eating out", "Groceries" ])
    end

    it "shows the envelope for a Spend or a Refund only, which the filing-record controller does, and says what the amount is" do
      get new_filing_rule_path

      assert_select "[data-controller~=filing-record]"
      assert_select "input[type=radio][name='filing_rule[outcome]'][data-filing-record-target=kind]", count: 4
      assert_select "[data-filing-record-target=group][data-kinds='refund spend'] select[name='filing_rule[envelope_id]']"
      expect(visible_text).to include("Leave it blank for any amount. Money out is negative, such as -82.45.")
    end

    it "says how many unfiled bank transactions a rule would fit, with a box, once there's text, and nothing before" do
      get new_filing_rule_path

      assert_select "turbo-frame#filing-rule-sweep"
      expect(visible_text).not_to include("unfiled bank transaction")
    end
  end

  describe "POST /filing_rules" do
    it "makes a rule, and goes to the list with a notice" do
      expect { post filing_rules_path, params: rule_params }.to change(budget.filing_rules, :count).by(1)

      expect(response).to redirect_to(filing_rules_path)
      follow_redirect!
      assert_select "[role=status]", text: "Filing rule added."
      expect(budget.filing_rules.sole).to have_attributes(text: "loblaws", outcome: "spend", envelope: groceries, account_id: nil, amount: nil)
    end

    it "makes a rule from scratch with an Account and an amount condition, which fits the next Import's matching bank transactions only" do
      other_account = create(:budget_account, budget: budget, name: "Visa")
      post filing_rules_path, params: rule_params(text: "PAYMENT  THANK YOU", account_id: chequing.id, amount: "-250.00", outcome: "ignore", envelope_id: "")
      csv_format = create(:budget_csv_format, budget: budget)

      right = chequing.imports.build(csv_format: csv_format, file_name: "a.csv").tap { |import| import.run("2026-09-01,Payment Thank You,-250.00\n2026-09-02,Payment Thank You,-100.00\n") }
      wrong = other_account.imports.build(csv_format: csv_format, file_name: "b.csv").tap { |import| import.run("2026-09-01,Payment Thank You,-250.00\n") }

      expect(budget.filing_rules.sole).to have_attributes(text: "payment thank you", account: chequing, amount: -250, outcome: "ignore", envelope_id: nil)
      expect(right).to have_attributes(ignored_by_rules: 1)
      expect(chequing.bank_transactions.find_by!(amount: -250)).to be_ignored
      expect(chequing.bank_transactions.find_by!(amount: -100)).to be_unfiled
      expect(wrong.bank_transactions.sole).to be_unfiled
    end

    it "never takes the budget from the form" do
      other_budget = create(:budget)

      post filing_rules_path, params: { filing_rule: rule_params[:filing_rule].merge(budget_id: other_budget.id) }

      expect(budget.filing_rules.count).to eq(1)
      expect(other_budget.filing_rules.count).to eq(0)
    end

    it "leaves the envelope out of a Deposit or an Ignore rule, which have none, though one was sent" do
      post filing_rules_path, params: rule_params(text: "acme payroll", outcome: "deposit")

      expect(budget.filing_rules.sole).to have_attributes(outcome: "deposit", envelope_id: nil)
    end

    it "says what's wrong, with the form as it was entered, and makes nothing" do
      expect { post filing_rules_path, params: rule_params(text: "lo", outcome: "spend", envelope_id: "", amount: "5") }.not_to change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Text is too short \(minimum is 3 characters\)/
      assert_select "[role=alert]", text: /Envelope can't be blank/
      assert_select "[role=alert]", text: /Amount must be negative, since a Spend is money out/
      assert_select "input[name='filing_rule[text]'][value=lo]"
      assert_select "input[name='filing_rule[amount]'][value='5']"
    end

    it "says there's nothing chosen to do, when nothing is" do
      post filing_rules_path, params: rule_params(outcome: "")

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /How to file them can't be blank/
    end

    it "refuses another budget's Account or envelope as an error on that field, and a made-up one" do
      post filing_rules_path, params: rule_params(account_id: create(:budget_account).id)
      assert_select "[role=alert]", text: /Account isn't one of this budget's/

      post filing_rules_path, params: rule_params(envelope_id: create(:budget_envelope).id)
      assert_select "[role=alert]", text: /Envelope isn't one of this budget's/

      post filing_rules_path, params: rule_params(account_id: "999999")
      assert_select "[role=alert]", text: /Account isn't one of this budget's/
      expect(Budget::FilingRule.count).to eq(0)
    end

    it "refuses an archived envelope" do
      create(:budget_envelope, budget: budget, name: "Old", archived_at: Time.current).then { |old| post filing_rules_path, params: rule_params(envelope_id: old.id) }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Envelope is archived/
    end

    it "refuses a rule with the same conditions as another, and says what the other one does, instead of updating it" do
      existing = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      expect { post filing_rules_path, params: rule_params(envelope_id: dining.id) }.not_to change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Another Filing rule already has the same text, Account and amount. It files them as Spend from Groceries./
      expect(existing.reload.envelope).to eq(groceries)
    end

    it "says which Account the other rule is for when it's for one" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: chequing)

      expect { post filing_rules_path, params: rule_params(envelope_id: dining.id, account_id: chequing.id) }.not_to change(Budget::FilingRule, :count)

      assert_select "[role=alert]", text: /Another Filing rule for 'loblaws' in Chequing already has the same text, Account and amount. It files them as Spend from Groceries./
    end

    it "says so, and not with an error page, when a rule with the same text was saved a moment ago, which only the unique index sees" do
      allow_any_instance_of(Budget::FilingRule).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      post filing_rules_path, params: rule_params

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Another Filing rule with the same text, Account and amount was saved a moment ago. Try again./
    end

    it "allows the same text with another Account or amount, which are other conditions" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      post filing_rules_path, params: rule_params(account_id: chequing.id)

      expect(budget.filing_rules.count).to eq(2)
    end

    it "files the unfiled bank transactions it fits when the box is ticked, in the same request, and says so" do
      account = create(:budget_account, budget: budget)
      rows = Array.new(2) { |n| create(:budget_bank_transaction, account: account, description: "LOBLAWS ##{n}", amount: -20) }
      untouched = create(:budget_bank_transaction, account: account, description: "SHELL", amount: -20)
      filed = create(:budget_bank_transaction, :filed, account: account, description: "LOBLAWS FILED")

      post filing_rules_path, params: { filing_rule: rule_params[:filing_rule].merge(sweep: "1") }

      follow_redirect!
      assert_select "[role=status]", text: "Filing rule added. It also filed 2 bank transactions."
      rule = budget.filing_rules.sole
      expect(rows.map { |row| row.reload.filing_rule_id }).to eq([ rule.id, rule.id ])
      expect(groceries.spends.count).to eq(2)
      expect([ untouched.reload ]).to all(be_unfiled)
      expect(filed.reload.filing_rule_id).to be_nil
    end

    it "sweeps with an Ignore rule in both directions, since there's no bank transaction it's being made from" do
      account = create(:budget_account, budget: budget)
      out = create(:budget_bank_transaction, account: account, description: "PAYMENT THANK YOU", amount: -250)
      back = create(:budget_bank_transaction, account: account, description: "PAYMENT THANK YOU", amount: 250, date: Date.new(2026, 9, 16))

      post filing_rules_path, params: { filing_rule: rule_params(text: "payment thank you", outcome: "ignore", envelope_id: "")[:filing_rule].merge(sweep: "1") }

      follow_redirect!
      assert_select "[role=status]", text: "Filing rule added. It also ignored 2 bank transactions."
      expect([ out.reload, back.reload ]).to all(be_ignored)
    end

    it "files none when the box is unticked or isn't sent, and still makes the rule" do
      row = create(:budget_bank_transaction, account: create(:budget_account, budget: budget), description: "LOBLAWS #1", amount: -20)

      post filing_rules_path, params: { filing_rule: rule_params[:filing_rule].merge(sweep: "0") }
      post filing_rules_path, params: rule_params(text: "loblaws #1", account_id: row.account_id)

      expect(budget.filing_rules.count).to eq(2)
      expect(row.reload).to be_unfiled
    end

    it "is one database transaction with its sweep, so a failure in the sweep leaves no rule" do
      create(:budget_bank_transaction, account: create(:budget_account, budget: budget), description: "LOBLAWS #1", amount: -20)
      allow_any_instance_of(Budget::FilingRule::Sweep).to receive(:run).and_raise(ActiveRecord::StatementInvalid, "the database went away")

      expect { post filing_rules_path, params: { filing_rule: rule_params[:filing_rule].merge(sweep: "1") } }.to raise_error(ActiveRecord::StatementInvalid)

      expect(Budget::FilingRule.count).to eq(0)
      expect(Budget::Spend.count).to eq(0)
    end
  end

  describe "GET /filing_rules/:id/edit" do
    let!(:rule) { create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws", account: chequing, amount: -82.45) }

    it "has the form filled in, and a Delete button that says what it keeps" do
      get edit_filing_rule_path(rule)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit Filing rule · Budgie"
      assert_select "form[action='#{filing_rule_path(rule)}'][method=post]" do
        assert_select "input[name=_method][value=patch]"
        assert_select "input[name='filing_rule[text]'][value=loblaws]"
        assert_select "select[name='filing_rule[account_id]'] option[selected]", text: "Chequing"
        assert_select "input[name='filing_rule[amount]'][value='-82.45']"
        assert_select "input[type=radio][name='filing_rule[outcome]'][value=spend][checked]"
        assert_select "select[name='filing_rule[envelope_id]'] option[selected]", text: "Groceries"
        assert_select "input[type=submit][value='Update Filing rule']"
      end
      assert_select "form[action='#{filing_rule_path(rule)}'][data-turbo-confirm]" do
        assert_select "button", text: "Delete"
      end
      expect(css_select("form[data-turbo-confirm]").first["data-turbo-confirm"]).to eq("Delete the Filing rule for 'loblaws'? The bank transactions it filed or ignored stay as they are.")
    end

    it "shows the amount to the cent, as a bank transaction's is, and as it was typed when it's being corrected" do
      rule.update!(amount: -45)

      get edit_filing_rule_path(rule)
      assert_select "input[name='filing_rule[amount]'][value='-45.00']"

      patch filing_rule_path(rule), params: rule_params(amount: "-45.5", text: "lo")
      assert_select "input[name='filing_rule[amount]'][value='-45.5']"
    end

    it "says how many unfiled bank transactions it fits as it stands, with a box to file or ignore them" do
      account = create(:budget_account, budget: budget)
      create(:budget_bank_transaction, account: chequing, description: "LOBLAWS #2", amount: -82.45)
      create(:budget_bank_transaction, account: account, description: "LOBLAWS #3", amount: -82.45)

      get edit_filing_rule_path(rule)

      expect(visible_text).to include("1 unfiled bank transaction fits.", "File or ignore them the same way now")
      assert_select "input[type=checkbox][name='filing_rule[sweep]'][checked]"
    end

    it "keeps the rule's own envelope in its picker when that's archived, and leaves other archived ones out" do
      create(:budget_envelope, budget: budget, name: "Old", archived_at: Time.current)
      groceries.update!(archived_at: Time.current)

      get edit_filing_rule_path(rule)

      expect(choices("envelope_id")).to eq([ "Choose an envelope", "Eating out", "Groceries" ])
      assert_select "select[name='filing_rule[envelope_id]'] option[selected]", text: "Groceries"
    end

    it "is not found for another user's rule" do
      get edit_filing_rule_path(others_rule)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /filing_rules/:id" do
    let!(:rule) { create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws") }
    let(:account) { create(:budget_account, budget: budget) }

    it "changes the rule, and goes to the list with a notice" do
      patch filing_rule_path(rule), params: rule_params(text: "loblaws toronto", account_id: chequing.id, amount: "-10", envelope_id: dining.id)

      expect(response).to redirect_to(filing_rules_path)
      follow_redirect!
      assert_select "[role=status]", text: "Filing rule updated."
      expect(rule.reload).to have_attributes(text: "loblaws toronto", account: chequing, amount: -10, envelope: dining)
    end

    it "can change what it does, which takes an envelope away from a Deposit or Ignore" do
      patch filing_rule_path(rule), params: rule_params(outcome: "ignore")

      expect(rule.reload).to have_attributes(outcome: "ignore", envelope_id: nil)
    end

    it "leaves the records it already filed where they are, and the bank transactions as they were filed, which only affects what comes in from then on" do
      row = create(:budget_bank_transaction, account: account, description: "LOBLAWS", amount: -20)
      Budget::FilingRule::Applier.new(budget).apply([ row.reload ])
      spend = row.reload.spend_links.sole.spend
      expect(spend.envelope).to eq(groceries)

      patch filing_rule_path(rule), params: rule_params(envelope_id: dining.id)

      expect(rule.reload.envelope).to eq(dining)
      expect(spend.reload.envelope).to eq(groceries)
      expect(row.reload).to be_filed
      expect(row.filing_rule_id).to eq(rule.id)
    end

    it "says what's wrong, with the form as it was entered, and changes nothing" do
      patch filing_rule_path(rule), params: rule_params(text: "lo")

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Text is too short/
      assert_select "input[name='filing_rule[text]'][value=lo]"
      expect(rule.reload.text).to eq("loblaws")
    end

    it "refuses the conditions of another rule, naming what it does" do
      create(:budget_filing_rule, :ignore, budget: budget, text: "costco")

      patch filing_rule_path(rule), params: rule_params(text: "costco")

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /It ignores them\./
    end

    it "keeps a rule on an archived envelope as it is, still inactive, when its text is edited" do
      groceries.update!(archived_at: Time.current)

      patch filing_rule_path(rule), params: rule_params(text: "loblaws toronto")

      expect(response).to redirect_to(filing_rules_path)
      expect(rule.reload).to have_attributes(text: "loblaws toronto", envelope: groceries)
      expect(rule).to be_inactive
    end

    it "refuses moving it into an archived envelope" do
      old = create(:budget_envelope, budget: budget, name: "Old", archived_at: Time.current)

      patch filing_rule_path(rule), params: rule_params(envelope_id: old.id)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert]", text: /Envelope is archived/
    end

    it "refuses another budget's Account or envelope" do
      patch filing_rule_path(rule), params: rule_params(account_id: create(:budget_account).id)
      assert_select "[role=alert]", text: /Account isn't one of this budget's/

      patch filing_rule_path(rule), params: rule_params(envelope_id: create(:budget_envelope).id)
      assert_select "[role=alert]", text: /Envelope isn't one of this budget's/
      expect(rule.reload).to have_attributes(account_id: nil, envelope: groceries)
    end

    it "files the unfiled bank transactions the rule now fits when the box is ticked, and leaves the filed and ignored ones" do
      row = create(:budget_bank_transaction, account: account, description: "COSTCO #1", amount: -20)
      ignored = create(:budget_bank_transaction, :ignored, account: account, description: "COSTCO #2", amount: -20)

      patch filing_rule_path(rule), params: { filing_rule: rule_params(text: "costco")[:filing_rule].merge(sweep: "1") }

      follow_redirect!
      assert_select "[role=status]", text: "Filing rule updated. It also filed 1 bank transaction."
      expect(row.reload.filing_rule_id).to eq(rule.id)
      expect(ignored.reload).to have_attributes(filing_rule_id: nil)
    end

    it "is not found for another user's rule, and takes the budget from nowhere" do
      patch filing_rule_path(others_rule), params: rule_params

      expect(response).to have_http_status(:not_found)
      expect(others_rule.reload.text).to eq("someone else's")
    end
  end

  describe "DELETE /filing_rules/:id" do
    let!(:rule) { create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws") }

    it "deletes the rule, keeps the records it filed, and clears the rule on the bank transactions it filed" do
      row = create(:budget_bank_transaction, account: create(:budget_account, budget: budget), description: "LOBLAWS", amount: -20)
      Budget::FilingRule::Applier.new(budget).apply([ row.reload ])
      spend = row.reload.spend_links.sole.spend

      expect { delete filing_rule_path(rule) }.to change(Budget::FilingRule, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(filing_rules_path)
      follow_redirect!
      assert_select "[role=status]", text: "Filing rule deleted."
      expect(Budget::Spend.exists?(spend.id)).to be(true)
      expect(row.reload).to be_filed
      expect(row.filing_rule_id).to be_nil
    end

    it "is not found for another user's rule" do
      others_rule

      expect { delete filing_rule_path(others_rule) }.not_to change(Budget::FilingRule, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /filing_rules/sweep, which the forms ask for as they're edited" do
    let(:account) { create(:budget_account, budget: budget) }

    before do
      create(:budget_bank_transaction, account: account, description: "LOBLAWS #1", amount: -20)
      create(:budget_bank_transaction, account: account, description: "LOBLAWS #2", amount: 20, date: Date.new(2026, 9, 16))
      create(:budget_bank_transaction, account: account, description: "SHELL", amount: -20)
    end

    def sweep(id: nil, **rule)
      get filing_rule_sweep_path, params: { id: id, filing_rule: rule }.compact, headers: { "Turbo-Frame" => "filing-rule-sweep" }
    end

    def frame_text
      Nokogiri::HTML(response.body).text.squish
    end

    it "answers with the frame, and how many unfiled bank transactions the rule as it's entered fits, with the box as it's ticked" do
      sweep(text: "loblaws", outcome: "spend", envelope_id: groceries.id, sweep: "1")

      expect(response).to have_http_status(:ok)
      assert_select "turbo-frame#filing-rule-sweep"
      expect(frame_text).to include("1 unfiled bank transaction fits.")
      assert_select "input[type=checkbox][name='filing_rule[sweep]'][checked]"

      sweep(text: "loblaws", outcome: "spend", envelope_id: groceries.id, sweep: "0")
      assert_select "input[type=checkbox][name='filing_rule[sweep]']:not([checked])"
    end

    it "fits either way for Ignore, and the sign for the other outcomes, and an Account or an amount when it has them" do
      sweep(text: "loblaws", outcome: "ignore")
      expect(frame_text).to include("2 unfiled bank transactions fit.")

      sweep(text: "loblaws", outcome: "refund", envelope_id: groceries.id)
      expect(frame_text).to include("1 unfiled bank transaction fits.")

      sweep(text: "loblaws", outcome: "ignore", amount: "-20")
      expect(frame_text).to include("1 unfiled bank transaction fits.")

      sweep(text: "loblaws", outcome: "ignore", account_id: create(:budget_account, budget: budget).id)
      expect(frame_text).to include("No unfiled bank transactions fit.")
    end

    it "says when a bank transaction fits but a more specific rule files it, and doesn't count it" do
      create(:budget_filing_rule, :ignore, budget: budget, text: "loblaws #1")

      sweep(text: "loblaws", outcome: "ignore")

      expect(frame_text).to include("1 unfiled bank transaction fits.", "1 more fits, but a more specific Filing rule files it.")
    end

    it "counts a rule that's being edited as it would be changed, in place of itself" do
      rule = create(:budget_filing_rule, budget: budget, envelope: groceries, text: "shell")

      sweep(id: rule.id, text: "loblaws", outcome: "spend", envelope_id: groceries.id)

      expect(frame_text).to include("1 unfiled bank transaction fits.")
    end

    it "says nothing of a count for a rule that isn't one yet, such as one with too little text, or one for another budget's envelope" do
      sweep(text: "lo", outcome: "ignore")
      expect(frame_text).not_to include("unfiled bank transaction")

      sweep(text: "loblaws", outcome: "spend", envelope_id: create(:budget_envelope).id)
      expect(frame_text).not_to include("unfiled bank transaction")

      sweep
      expect(frame_text).not_to include("unfiled bank transaction")
    end

    it "is not found for another user's rule, and needs sign-in" do
      sweep(id: others_rule.id, text: "loblaws", outcome: "ignore")
      expect(response).to have_http_status(:not_found)

      delete session_path
      sweep(text: "loblaws", outcome: "ignore")
      expect(response).to redirect_to(sign_in_path)
    end
  end
end
