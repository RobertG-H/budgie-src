require "rails_helper"

# The header's links to the pages that aren't a month's.
RSpec.describe "Navigation", type: :request do
  let(:budget) { create(:budget) }

  it "offers a signed-in person with a budget a link to each section, and says which they're on" do
    sign_in_as budget.user

    get csv_formats_path

    assert_select "header nav[aria-label=Sections] a", count: 6
    assert_select "header nav[aria-label=Sections] a[href='#{root_path}']:not([aria-current])", text: "Budget"
    assert_select "header nav[aria-label=Sections] a[href='#{records_path}']:not([aria-current])", text: "Records"
    assert_select "header nav[aria-label=Sections] a[href='#{accounts_path}']:not([aria-current])", text: "Accounts"
    assert_select "header nav[aria-label=Sections] a[href='#{bank_transactions_path}']:not([aria-current])", text: "Bank transactions"
    assert_select "header nav[aria-label=Sections] a[href='#{filing_rules_path}']:not([aria-current])", text: "Filing rules"
    assert_select "header nav[aria-label=Sections] a[href='#{csv_formats_path}'][aria-current=page]", text: "CSV formats"
  end

  it "puts the sections in order: Budget, Records, Bank transactions, Accounts, Filing rules, CSV formats" do
    sign_in_as budget.user

    get root_path

    names = css_select("header nav[aria-label=Sections] > ul > li").map { |item| item.at_css("a").text.squish }
    expect(names).to eq([ "Budget", "Records", "Bank transactions", "Accounts", "Filing rules", "CSV formats" ])
  end

  it "says Budget is the one they're on in a month, and on its pages" do
    sign_in_as budget.user

    [ root_path, month_path("2026-09"), month_deposits_path("2026-09") ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{root_path}'][aria-current=page]", text: "Budget"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  it "says Records is the one they're on in the Records list" do
    sign_in_as budget.user

    get records_path

    assert_select "nav[aria-label=Sections] a[href='#{records_path}'][aria-current=page]", text: "Records"
    assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
  end

  it "says Bank transactions is the one they're on in the list, in any state, and in the review of what's guessed" do
    sign_in_as budget.user

    [ bank_transactions_path, bank_transactions_path(filter: { state: "unfiled" }), new_guessed_filing_path ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{bank_transactions_path}'][aria-current=page]", text: "Bank transactions"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  it "has no link to the Unfiled list any more, which is a state of the Bank transactions page" do
    sign_in_as budget.user

    get root_path

    assert_select "nav[aria-label=Sections] a", text: "Unfiled", count: 0
  end

  it "says Filing rules is the one they're on in the list, and while making or changing one" do
    sign_in_as budget.user
    rule = create(:budget_filing_rule, budget: budget)

    [ filing_rules_path, new_filing_rule_path, edit_filing_rule_path(rule) ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{filing_rules_path}'][aria-current=page]", text: "Filing rules"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  it "says CSV formats is the one they're on while building or changing one" do
    sign_in_as budget.user
    format = create(:budget_csv_format, budget: budget)

    [ new_csv_format_path, edit_csv_format_path(format) ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{csv_formats_path}'][aria-current=page]", text: "CSV formats"
    end
  end

  it "says Accounts is the one they're on at an Account, its Import's form, and an Import's summary" do
    sign_in_as budget.user
    account = create(:budget_account, budget: budget)
    import = create(:budget_import, account: account)

    [ accounts_path, new_account_path, account_path(account), edit_account_path(account), new_account_import_path(account), import_path(import) ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{accounts_path}'][aria-current=page]", text: "Accounts"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  describe "the section a form belongs to, which is where it was opened from" do
    let(:envelope) { create(:budget_envelope, budget: budget, name: "Groceries") }
    let(:other_envelope) { create(:budget_envelope, budget: budget, name: "Household") }
    let(:spend) { create(:budget_spend, envelope: envelope, date: Date.new(2026, 9, 12)) }
    let(:refund) { create(:budget_refund, envelope: envelope, date: Date.new(2026, 9, 12)) }
    let(:deposit) { create(:budget_deposit, budget: budget, date: Date.new(2026, 9, 12)) }
    let(:reallocation) { create(:budget_envelope_reallocation, from_envelope: envelope, to_envelope: other_envelope, date: Date.new(2026, 9, 12)) }
    let(:to_ready_to_assign) { create(:budget_ready_to_assign_reallocation, envelope: envelope, date: Date.new(2026, 9, 12)) }
    let(:account) { create(:budget_account, budget: budget) }

    before { sign_in_as budget.user }

    def expect_only(section)
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1, text: section
    end

    it "is Budget for a form opened from the month view, a month's Deposits or an envelope's page, and for the envelope forms" do
      [ new_spend_path(month: "2026-09", from: "home"),
        new_spend_path(month: "2026-09", from: "month"),
        new_deposit_path(month: "2026-09", from: "deposits"),
        new_refund_path(month: "2026-09", from: "envelope", envelope: envelope.id),
        new_reallocation_path(month: "2026-09", from: "envelope", envelope: envelope.id),
        edit_spend_path(spend, month: "2026-09", from: "envelope"),
        edit_refund_path(refund, month: "2026-09", from: "envelope"),
        edit_deposit_path(deposit, month: "2026-09", from: "deposits"),
        edit_envelope_reallocation_path(reallocation, month: "2026-09", from: "envelope", envelope: envelope.id),
        edit_ready_to_assign_reallocation_path(to_ready_to_assign, month: "2026-09", from: "deposits"),
        new_envelope_path(month: "2026-09", from: "month"),
        edit_envelope_path(envelope, month: "2026-09", from: "envelope") ].each do |path|
        get path

        expect(response).to have_http_status(:ok), path
        expect_only "Budget"
      end
    end

    it "is Budget for an envelope's form whatever it says it was opened from, since only the month view opens them" do
      get edit_envelope_path(envelope, month: "2026-09", from: "records")

      expect_only "Budget"
    end

    it "is Budget for a form that wasn't opened from anywhere, which goes back to the month" do
      get new_spend_path(month: "2026-09")

      expect_only "Budget"
    end

    it "is Budget for an Assigned input, which is part of the month view" do
      get edit_month_envelope_assignment_path("2026-09", envelope)

      expect_only "Budget"
    end

    it "is Records for a record's edit form opened from the Records page" do
      [ edit_spend_path(spend, from: "records"),
        edit_refund_path(refund, from: "records"),
        edit_deposit_path(deposit, from: "records"),
        edit_envelope_reallocation_path(reallocation, from: "records"),
        edit_ready_to_assign_reallocation_path(to_ready_to_assign, from: "records") ].each do |path|
        get path

        expect(response).to have_http_status(:ok), path
        expect_only "Records"
      end
    end

    it "is Records when a form opened from the Records page comes back refused" do
      patch spend_path(spend), params: { from: "records", spend: { amount: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect_only "Records"
    end

    it "is Bank transactions for a record's edit form opened from the Bank transactions page, and for a bank transaction's filing form" do
      bank_transaction = create(:budget_bank_transaction, account: account)

      [ edit_spend_path(spend, from: "bank_transactions"),
        edit_deposit_path(deposit, from: "bank_transactions"),
        new_bank_transaction_filing_path(bank_transaction, from: "account"),
        new_bank_transaction_filing_path(bank_transaction, from: "bank_transactions") ].each do |path|
        get path

        expect(response).to have_http_status(:ok), path
        expect_only "Bank transactions"
      end
    end

    it "is Accounts for a record's edit form opened from an Account's page" do
      get edit_spend_path(spend, from: "account")

      expect_only "Accounts"
    end

    it "is Accounts for the whole Import form and an Import's summary, and never marks Import, which is a button and not a section" do
      import = create(:budget_import, account: account)

      [ new_import_path, import_path(import) ].each do |path|
        get path

        expect_only "Accounts"
        assert_select "nav[aria-label=Main] a[aria-current]", count: 0
      end
    end

    it "is Accounts when the whole Import form comes back refused" do
      post imports_path, params: { import: { account_id: account.id } }

      expect(response).to have_http_status(:unprocessable_content)
      expect_only "Accounts"
    end
  end

  describe "the count of unfiled bank transactions" do
    let(:account) { create(:budget_account, budget: budget) }
    let(:import) { create(:budget_import, account: account) }

    before { sign_in_as budget.user }

    def make_unfiled(count)
      create_list(:budget_bank_transaction, count, account: account, import: import)
    end

    def count_link
      css_select("nav[aria-label=Sections] li a").find { |link| link.text.include?("unfiled") }
    end

    it "follows Bank transactions, in words, and is a link to the Unfiled state" do
      make_unfiled(12)

      get root_path

      item = css_select("nav[aria-label=Sections] li").find { |li| li.at_css("a").text.squish == "Bank transactions" }
      links = item.css("a")
      expect(links.map { |link| link.text.squish }).to eq([ "Bank transactions", "12 unfiled" ])
      expect(links.first["href"]).to eq(bank_transactions_path)
      expect(links.last["href"]).to eq(bank_transactions_path(filter: { state: "unfiled" }))
    end

    it "counts only the unfiled ones, not the filed or ignored" do
      make_unfiled(2)
      create(:budget_bank_transaction, :filed, account: account, import: import)
      create(:budget_bank_transaction, :ignored, account: account, import: import)

      get root_path

      expect(count_link.text.squish).to eq("2 unfiled")
    end

    it "counts the whole budget's, across its Accounts, and not another budget's" do
      other_account = create(:budget_account, budget: budget)
      make_unfiled(1)
      create(:budget_bank_transaction, account: other_account)
      create(:budget_bank_transaction, account: create(:budget_account, budget: create(:budget)))

      get root_path

      expect(count_link.text.squish).to eq("2 unfiled")
    end

    it "is there on every page that has the header" do
      make_unfiled(3)

      [ records_path, accounts_path, bank_transactions_path, csv_formats_path ].each do |path|
        get path

        expect(count_link.text.squish).to eq("3 unfiled")
      end
    end

    it "is muted, and marks no page as current by itself" do
      make_unfiled(3)

      get bank_transactions_path

      expect(count_link["class"]).to include("text-base-content/70")
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1, text: "Bank transactions"
    end

    it "is capped: 99 is 99 and a hundred or more is 99+" do
      make_unfiled(99)
      get root_path
      expect(count_link.text.squish).to eq("99 unfiled")

      make_unfiled(1)
      get root_path
      expect(count_link.text.squish).to eq("99+ unfiled")

      make_unfiled(3)
      get root_path
      expect(count_link.text.squish).to eq("99+ unfiled")
    end

    it "is left out when there are none" do
      create(:budget_bank_transaction, :ignored, account: account, import: import)

      get root_path

      expect(count_link).to be_nil
      assert_select "nav[aria-label=Sections] a", count: 6
    end

    it "is one query, however many bank transactions there are, read once per request" do
      make_unfiled(30)
      statements = []
      collector = ->(*, payload) { statements << payload[:sql] if payload[:sql].include?("budget_bank_transactions") }

      ActiveSupport::Notifications.subscribed(collector, "sql.active_record") { get csv_formats_path }

      expect(statements.size).to eq(1)
      expect(statements.first).to include("LIMIT")
    end
  end

  it "has Import beside Sign out in the main navigation, whenever the person has a budget, as the primary button" do
    sign_in_as budget.user

    [ root_path, accounts_path, records_path, csv_formats_path ].each do |path|
      get path

      assert_select "nav[aria-label=Main] a.btn.btn-primary.btn-sm[href='#{new_import_path}']", text: "Import", count: 1
      assert_select "nav[aria-label=Main] a", count: 1
      assert_select "nav[aria-label=Main] button", text: "Sign out"
    end
  end

  describe "the Import button's file chooser" do
    let!(:csv_format) { create(:budget_csv_format, budget: budget) }
    let!(:account) { create(:budget_account, budget: budget) }

    before { sign_in_as budget.user }

    it "is attached, with a hidden form that sends the file to be guessed, when the budget has a CSV format and an Account" do
      get root_path

      assert_select "nav[aria-label=Main] [data-controller=import-picker]", count: 1
      assert_select "nav[aria-label=Main] a.btn[data-action='import-picker#choose'][href='#{new_import_path}']", text: "Import"
      assert_select "nav[aria-label=Main] form.hidden[action='#{import_guess_path}'][method=post][enctype='multipart/form-data'][data-import-picker-target=form]" do
        assert_select "input[type=file][name='import[file]'][accept='.csv,text/csv'][data-import-picker-target=input][data-action='change->import-picker#send'][tabindex='-1']"
      end
    end

    it "is only a link to the whole form without a CSV format, so the person lands on the page that says what's missing" do
      Budget::CsvFormat.where(budget: budget).delete_all
      Budget::Account.update_all(default_csv_format_id: nil)

      get root_path

      assert_select "nav[aria-label=Main] a.btn[href='#{new_import_path}']", text: "Import"
      assert_select "[data-controller=import-picker]", count: 0
      assert_select "form[action='#{import_guess_path}']", count: 0
    end

    it "is only a link without an Account too" do
      Budget::Account.where(budget: budget).delete_all

      get root_path

      assert_select "nav[aria-label=Main] a.btn[href='#{new_import_path}']", text: "Import"
      assert_select "[data-controller=import-picker]", count: 0
    end

    it "is a link that works without JavaScript: it's a plain link to a page with a form" do
      get root_path

      assert_select "nav[aria-label=Main] a[href='#{new_import_path}']", count: 1
      get new_import_path
      assert_select "form[action='#{imports_path}'] input[type=file]"
    end
  end

  it "has no Import for a person who hasn't got a budget yet, only Sign out" do
    sign_in_as create(:user)

    get new_budget_path

    assert_select "nav[aria-label=Main] a", count: 0
    assert_select "nav[aria-label=Main] button", text: "Sign out"
  end

  it "is left out until there's a budget to go to" do
    sign_in_as create(:user)

    get new_budget_path

    assert_select "nav[aria-label=Sections]", count: 0
  end

  it "is left out when signed out" do
    get sign_in_path

    assert_select "nav[aria-label=Sections]", count: 0
  end
end
