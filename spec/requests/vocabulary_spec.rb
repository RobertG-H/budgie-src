require "rails_helper"

# The UI uses only the terms CLAUDE.md lists. Internal names (tables, columns) stay out of it, and so do the terms
# GLOSSARY.md says to avoid.
RSpec.describe "The words on the pages", type: :request do
  let(:retired_terms) do
    /\b(categor(y|ies)|income|inflow|outflow|budgeted|spending|expense|purchase|payment|transfer|move|reimbursement|repayment|wallet|(?<!bank\s)transaction|payee|payer)\b/i
  end
  let(:budget) { create(:budget) }
  let!(:bills) { create(:budget_envelope, budget: budget, name: "Bills", starting_balance: -30) }
  let!(:paycheck) do
    create(:budget_deposit, budget: budget, description: "Paycheck", date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1), amount: 3000, notes: "Biweekly")
  end

  # Money assigned to Bills, in the month the pages below are for and the one before it.
  let!(:assignments) do
    [ create(:budget_assignment, envelope: bills, month: Date.new(2026, 10, 1), amount: 40),
      create(:budget_assignment, envelope: bills, month: Date.new(2026, 9, 1), amount: 5) ]
  end

  # Money spent from Bills, in the month the pages below are for.
  let!(:spend) do
    create(:budget_spend, envelope: bills, description: "Hydro", date: Date.new(2026, 10, 12), amount: 65.5, notes: "September's bill")
  end

  # Money that came back to Bills, in the month the pages below are for.
  let!(:refund) do
    create(:budget_refund, envelope: bills, description: "Hydro rebate", date: Date.new(2026, 10, 20), amount: 12.25, notes: "Credited in October")
  end

  # Money moved out of Bills into another envelope, in the month the pages below are for.
  let!(:reallocation) do
    create(:budget_envelope_reallocation, from_envelope: bills, to_envelope: create(:budget_envelope, budget: budget, name: "Fuel"),
      description: "Covering the gas", date: Date.new(2026, 10, 22), amount: 8.75, notes: "Only this once")
  end

  # Money moved out of Bills back into Ready to Assign, in the month the pages below are for.
  let!(:to_ready_to_assign) do
    create(:budget_ready_to_assign_reallocation, envelope: bills, description: "Unspent gas money", date: Date.new(2026, 10, 25), amount: 3.5, notes: "Back to the pool")
  end

  # How one of the budget's banks lays out its CSV download.
  let!(:csv_format) { create(:budget_csv_format, budget: budget, name: "CIBC", description_columns: [ 2, 1 ]) }

  # Where bank transactions come from, with an Import of three rows, one of them of 0.
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:import) do
    plain = create(:budget_csv_format, budget: budget, name: "Plain")
    account.imports.build(csv_format: plain, file_name: "sept.csv").tap { |i| i.run("2026-10-01,Paycheck,2800.00\n2026-10-02,Loblaws,-82.45\n2026-10-03,Interest,0.00\n") }
  end

  # Filing rules, made after the Import above so that its rows aren't filed by them: one for a Spend, one that ignores, and one for an
  # envelope that's archived, which is inactive.
  let!(:filing_rules) do
    closed = create(:budget_envelope, budget: budget, name: "Closed")
    rules = [ create(:budget_filing_rule, budget: budget, envelope: bills, text: "loblaws", amount: -82.45, account: account),
              create(:budget_filing_rule, :ignore, budget: budget, text: "coffee shop"),
              create(:budget_filing_rule, budget: budget, envelope: closed, text: "gym membership") ]
    closed.archive!
    rules
  end

  before { sign_in_as budget.user }

  # What a person reads on the page, not its markup.
  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  {
    "the month view" => -> { month_path("2026-10") },
    "a month's Deposits" => -> { month_deposits_path("2026-10") },
    "the envelope page" => -> { month_envelope_path("2026-10", bills) },
    "the Assigned input" => -> { edit_month_envelope_assignment_path("2026-10", bills) },
    "the Records" => -> { records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" }) }
  }.each do |page, path|
    it "has no table or column names in #{page}" do
      get instance_exec(&path)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to match(/budget_|starting_balance|carried_over|ready_to_assign|_id\b/)
      expect(visible_text).not_to match(/\w+_\w+/)
    end
  end

  {
    "the month view" => -> { month_path("2026-10") },
    "a month's Deposits" => -> { month_deposits_path("2026-10") },
    "the envelope page" => -> { month_envelope_path("2026-10", bills) },
    "the Deposit form" => -> { new_deposit_path(month: "2026-10", from: "month") },
    "the Deposit edit form" => -> { edit_deposit_path(paycheck, month: "2026-10", from: "deposits") },
    "the Spend form" => -> { new_spend_path(month: "2026-10", from: "envelope", envelope: bills.id) },
    "the Spend edit form" => -> { edit_spend_path(spend, month: "2026-10", from: "envelope") },
    "the Refund form" => -> { new_refund_path(month: "2026-10", from: "envelope", envelope: bills.id) },
    "the Refund edit form" => -> { edit_refund_path(refund, month: "2026-10", from: "envelope") },
    "the Reallocate form" => -> { new_reallocation_path(month: "2026-10", from: "envelope", envelope: bills.id) },
    "the Reallocation edit form" => -> { edit_envelope_reallocation_path(reallocation, month: "2026-10", from: "envelope", envelope: bills.id) },
    "the edit form of a Reallocation to Ready to Assign" => -> { edit_ready_to_assign_reallocation_path(to_ready_to_assign, month: "2026-10", from: "deposits") },
    "the envelope form" => -> { new_envelope_path(month: "2026-10", from: "month") },
    "the envelope edit form" => -> { edit_envelope_path(bills, month: "2026-10", from: "envelope") },
    "the Assigned input" => -> { edit_month_envelope_assignment_path("2026-10", bills) },
    "the CSV formats" => -> { csv_formats_path },
    "the CSV format form" => -> { new_csv_format_path },
    "the CSV format edit form" => -> { edit_csv_format_path(csv_format) },
    "the Accounts" => -> { accounts_path },
    "the Account form" => -> { new_account_path },
    "the Account edit form" => -> { edit_account_path(account) },
    "an Account's page" => -> { account_path(account) },
    "the Import form" => -> { new_account_import_path(account) },
    "the whole Import form" => -> { new_import_path },
    "an Import's summary" => -> { import_path(import) },
    "the Bank transactions" => -> { bank_transactions_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" }) },
    "the Bank transactions, Unfiled" => -> { bank_transactions_path(filter: { state: "unfiled" }) },
    "the Bank transactions, Filed" => -> { bank_transactions_path(filter: { state: "filed", date_from: "2026-10-01", date_to: "2026-10-31" }) },
    "the Bank transactions, Ignored" => -> { bank_transactions_path(filter: { state: "ignored", date_from: "2026-10-01", date_to: "2026-10-31" }) },
    "the Bank transactions, with nothing that matches" => -> { bank_transactions_path(filter: { state: "ignored", date_from: "2000-01-01", date_to: "2000-01-31" }) },
    "the Records" => -> { records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" }) },
    "the Records, filtered to Reallocations" => -> { records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", kind: "reallocation" }) },
    "the Records, of an envelope" => -> { records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31", envelope: bills.id.to_s }) },
    "the Records, with a range that can't be used" => -> { records_path(filter: { date_from: "2026-10-31", date_to: "2026-10-01" }) },
    "the Records, with nothing in the range" => -> { records_path(filter: { date_from: "2020-01-01", date_to: "2020-01-31" }) },
    "the Records, past the last page" => -> { records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" }, page: 9) },
    "the Filing rules" => -> { filing_rules_path },
    "the Filing rule form" => -> { new_filing_rule_path },
    "the Filing rule edit form" => -> { edit_filing_rule_path(budget.filing_rules.find_by!(text: "loblaws")) },
    "the filing form for money in" => -> { new_bank_transaction_filing_path(account.bank_transactions.find_by!(description: "Paycheck"), from: "bank_transactions", filter: { state: "unfiled" }) },
    "the filing form for money out" => -> { new_bank_transaction_filing_path(account.bank_transactions.find_by!(description: "Loblaws"), from: "account") }
  }.each do |page, path|
    it "has no snake_case names and no retired terms in the words on #{page}" do
      get instance_exec(&path)

      expect(response).to have_http_status(:ok)
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)
    end
  end

  describe "Records" do
    it "says Records, the kinds of record and the money in and out, in words" do
      get records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" })

      expect(visible_text).to include("Records", "Money in", "Money out", "Kind", "Envelope", "From", "To")
      expect(visible_text).to include("Spend from Bills", "Refund to Bills", "Deposit", "Reallocation from Bills to Fuel", "Reallocation from Bills to Ready to Assign")
      expect(visible_text).to include("Reallocations only change which envelope money is in, so they aren't counted.")
      expect(visible_text).to include("This month", "Last month", "Last 3 months")
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)
    end

    it "never spells Ready to Assign with underscores in a path, a param or an id" do
      get records_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" })

      expect(response.body).not_to match(/ready_to_assign/)
      expect(response.body).to include("/reallocations/to-ready-to-assign/")
    end
  end

  describe "Accounts and Imports" do
    it "tells a bare transaction from a Bank transaction, which is a term" do
      expect("Bank transaction").not_to match(retired_terms)
      expect("No bank transactions yet.").not_to match(retired_terms)
      expect("Every transaction was already here").to match(retired_terms)
      expect("A transaction").to match(retired_terms)
    end

    describe "importing from the header" do
      def guess(text, name: "october.csv")
        post import_guess_path, params: { import: { file: Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: name) } }
      end

      it "says what was guessed, and what to check, in words, when the CSV format reads it differently or no Account has it as its default" do
        guess("2026-10-01,Paycheck,2800.00\n")

        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_text).to include("Import", "Choose a file, the CSV format that reads it and the Account it's for.", "Choose the file again.")
        expect(visible_text).to include("More than one of your CSV formats reads this file. Check the CSV format.")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)
        expect(response.body).not_to match(/ready_to_assign|import_guess|csv_format_id\b.*Csv format/)
      end

      it "says why no CSV format reads a file, format by format, and points to the builder, in words" do
        guess("nonsense\n")

        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_text).to include("No CSV format reads this file.", "Why", "CIBC: Line 1: has 1 column, and this CSV format expects 3.")
        expect(visible_text).to include("New CSV format", "In the CSV format builder, choose the same file as its sample.")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)
      end

      it "says what's wrong with the file once, in the reader's words, when it's every format's" do
        guess("2026-10-01,Caf\xE9,-5.00\n".b)

        expect(visible_text).to include("The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again. Choose another file.")
        expect(visible_text).not_to match(retired_terms)
      end

      it "says on the summary which Account and CSV format an Import used, in words" do
        get import_path(import)

        expect(visible_text).to include("Into Chequing, read with the Plain CSV format.")
        expect(visible_text).not_to match(retired_terms)
      end

      it "says what an Import from the header did, in the notice, in words, when it's certain" do
        # CIBC now reads exactly what Plain does, so they're one format, and Chequing is the Account that has Plain as its default.
        csv_format.update!(description_columns: [ 2 ])
        expect(account.reload.default_csv_format).to be_present

        guess("2026-10-01,Paycheck,2800.00\n")

        expect(response).to have_http_status(:found)
        follow_redirect!
        expect(response).to have_http_status(:ok)
        expect(visible_text).to include("Imported october.csv into Chequing, read with the Plain CSV format.")
        expect(visible_text).not_to match(retired_terms)
      end
    end

    it "says Default CSV format, and what it's for, on the Account's form and page, in words" do
      account.update!(default_csv_format: csv_format)

      get edit_account_path(account)

      expect(visible_text).to include("Default CSV format", "None", "Used to recognise which Account a file is for when you Import from the header.")
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)

      get account_path(account)

      expect(visible_text).to include("Default CSV format: CIBC")
      expect(visible_text).not_to match(retired_terms)

      patch account_path(account), params: { account: { name: "Chequing", default_csv_format_id: create(:budget_csv_format).id } }

      expect(visible_text).to include("Default CSV format isn't one of this budget's")
      expect(visible_text).not_to match(retired_terms)
    end

    it "says Bank transactions, and Import, on an Account's page, in words" do
      get account_path(account)

      expect(visible_text).to include("Chequing", "Import", "Latest Import: sept.csv", "Oct 1, 2026", "Paycheck", "$2,800.00", "Loblaws", "-$82.45")
      expect(visible_text).not_to include("Interest")
    end

    it "says what an Import did in words a person uses, with no column names" do
      get import_path(import)

      expect(visible_text).to include("Added 2 bank transactions", "Money in $2,800.00 1 bank transaction in the file", "Money out -$82.45 1 bank transaction in the file",
        "Duplicates skipped 0", "Rows of 0 skipped 1", "First row", "Oct 1, 2026 Paycheck Money in $2,800.00")
      expect(response.body).not_to match(/budget_|zero_rows|duplicates_skipped|content_key|occurrence/)
    end

    describe "filing" do
      let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
      let(:loblaws_row) { account.bank_transactions.find_by!(description: "Loblaws") }
      let(:paycheck_row) { account.bank_transactions.find_by!(description: "Paycheck") }

      def file_params(**attributes)
        { filing: { records: { "0" => { kind: "spend", envelope_id: groceries.id, description: "Loblaws", date: "2026-10-02", amount: "82.45" }.merge(attributes) } } }
      end

      it "says Unfiled, Filed and Ignored, and Un-file and Un-ignore, with the flag in words, on an Account's page" do
        post bank_transaction_filing_path(loblaws_row), params: file_params
        paycheck_row.ignore
        extra = create(:budget_bank_transaction, account: account, description: "Hydro", date: Date.new(2026, 10, 4), amount: -65.5)
        loblaws_row.spend_links.sole.spend.update!(amount: 80)

        get account_path(account)

        expect(visible_text).to include("Unfiled", "Filed", "Ignored", "Un-file", "Un-ignore", "Spend from Groceries", "Doesn't add up", "Its records add up to $80.00, not $82.45.")
        expect(extra).to be_unfiled
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)
      end

      it "says Filing rule, and what a rule did, in words: on the filing form with the box and its message, on the summary and on an Account's page" do
        budget_groceries = groceries
        create(:budget_filing_rule, budget: budget, envelope: budget_groceries, text: "loblaws", account: account)
        create(:budget_filing_rule, :ignore, budget: budget, text: "hydro")
        hydro = create(:budget_bank_transaction, account: account, description: "Hydro", date: Date.new(2026, 10, 4), amount: -65.5)
        Budget::FilingRule::Applier.new(budget).apply([ hydro.reload ])
        create(:budget_bank_transaction, account: account, description: "Loblaws", date: Date.new(2026, 10, 5), amount: -20)

        get new_bank_transaction_filing_path(loblaws_row, from: "account")

        expect(visible_text).to include("Always file like this", "Text to look for", "Updates the Filing rule for 'loblaws' in Chequing, which files them as Spend from Groceries now.",
          "1 other unfiled bank transaction fits.", "File or ignore them the same way now", "Only the ones that went the same way as this one.")

        get bank_transaction_rule_preview_path(loblaws_row), params: { filing: { rule: { text: "loblaws", sweep: "1" } } }, headers: { "Turbo-Frame" => "filing-rule-preview" }

        frame_text = Nokogiri::HTML(response.body).text.squish
        expect(frame_text).to include("1 other unfiled bank transaction fits.")
        expect(frame_text).not_to match(/\w+_\w+/)
        expect(frame_text).not_to match(retired_terms)

        get new_bank_transaction_filing_path(loblaws_row, from: "account")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)

        get account_path(account)

        expect(visible_text).to include("Filing rule: hydro → Ignore")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)

        get import_path(import)

        expect(visible_text).to include("Filed by Filing rules", "Ignored by Filing rules")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(response.body).not_to match(/filed_by_rules|ignored_by_rules/)
      end

      it "says File and next, Ignore and next, Edit details and Edit rule, and what happens when none is left, in words" do
        # Paycheck and Loblaws are the two unfiled bank transactions of the Import above.
        get new_bank_transaction_filing_path(paycheck_row, from: "bank_transactions", filter: { state: "unfiled" })

        expect(visible_text).to include("File and next", "Ignore and next", "Edit details", "Paycheck · Oct 1, 2026 · $2,800.00", "Edit rule", "Always file like this", "Only in Chequing", "Any account",
          "Chequing bank transactions with 'paycheck' in their description are filed the same way as they come in.",
          "Bank transactions in any account with 'paycheck' in their description are filed the same way as they come in.")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)

        post bank_transaction_ignore_path(paycheck_row), params: { next: "1", from: "bank_transactions", filter: { state: "unfiled" } }
        follow_redirect!

        expect(Nokogiri::HTML(response.body).text.squish).to include("Bank transaction ignored.")
        expect(visible_text).not_to include("and next")
        expect(visible_text).not_to match(retired_terms)

        post bank_transaction_ignore_path(loblaws_row), params: { next: "1", from: "bank_transactions", filter: { state: "unfiled" } }
        follow_redirect!

        expect(Nokogiri::HTML(response.body).text.squish).to include("Bank transaction ignored. No more unfiled bank transactions.")
        expect(Nokogiri::HTML(response.body).text.squish).not_to match(retired_terms)
      end

      it "says Guess, and which bank transaction it was like, on the filing form, in words" do
        post bank_transaction_filing_path(loblaws_row), params: file_params
        later_paycheck = create(:budget_bank_transaction, account: account, description: "Paycheck", date: Date.new(2026, 10, 15), amount: 2800)
        similar = create(:budget_bank_transaction, account: account, description: "Loblaws", date: Date.new(2026, 10, 6), amount: -20)

        get new_bank_transaction_filing_path(similar.reload, from: "bank_transactions", filter: { state: "unfiled" })

        expect(visible_text).to include("Guess: like Loblaws → Groceries")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)
        expect(response.body).not_to match(/guess_|_guess|draft_attributes/)

        get new_bank_transaction_filing_path(later_paycheck.reload, from: "bank_transactions", filter: { state: "unfiled" })

        expect(visible_text).not_to include("Guess")
      end

      it "says Guess, File as guessed and what it did in words, on the Unfiled list, its review, and when the review is refused or empty" do
        post bank_transaction_filing_path(loblaws_row), params: file_params
        similar = create(:budget_bank_transaction, account: account, description: "Loblaws", date: Date.new(2026, 10, 6), amount: -20)

        get bank_transactions_path(filter: { state: "unfiled" })

        expect(visible_text).to include("File 1 as guessed", "Guess: like Loblaws → Groceries")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)

        get new_guessed_filing_path

        expect(visible_text).to include("File as guessed", "1 bank transaction on this page has a Guess. Untick any you'd rather file yourself.", "Guess: like Loblaws → Groceries")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)
        expect(response.body).not_to match(/budget_|_id\b|review_value|draft_attributes/)

        groceries.update!(archived_at: Time.current)
        post guessed_filing_path, params: { guessed: { similar.id.to_s => "spend:#{groceries.id}" } }
        follow_redirect!

        expect(visible_text).to include("Nothing was filed. Loblaws: Envelope is archived.", "None of the bank transactions on this page has a Guess.", "Back to Unfiled")
        expect(visible_text).not_to match(retired_terms)

        groceries.update!(archived_at: nil)
        post guessed_filing_path, params: { guessed: { similar.id.to_s => "spend:#{groceries.id}" } }
        follow_redirect!

        expect(visible_text).to include("1 bank transaction filed as guessed.")
        expect(visible_text).not_to match(retired_terms)

        post guessed_filing_path
        follow_redirect!

        expect(visible_text).to include("Choose at least one bank transaction to file.")
        expect(visible_text).not_to match(retired_terms)
      end

      it "says what's wrong with a rule in the same words, when it's refused with a filing or an ignoring" do
        post bank_transaction_filing_path(loblaws_row), params: { filing: { records: file_params[:filing][:records], rule: { make: "1", text: "lo" } } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_text).to include("Text is too short (minimum is 3 characters)")
        expect(visible_text).not_to match(retired_terms)

        post bank_transaction_filing_path(loblaws_row), params: { filing: { records: file_params[:filing][:records], rule: { make: "1", text: "costco" } } }

        expect(visible_text).to include("Text must be part of the bank transaction's description, so that the rule fits it")
        expect(visible_text).not_to match(retired_terms)
      end

      it "says what a filed record came from, on its edit page, and the confirmation for un-filing, in the same words" do
        post bank_transaction_filing_path(loblaws_row), params: file_params
        spend = loblaws_row.spend_links.sole.spend

        get edit_spend_path(spend, month: "2026-10")

        expect(visible_text).to include("Filed from a bank transaction in Chequing, Oct 2, 2026, Loblaws. Deleting it un-files that bank transaction.")
        expect(visible_text).not_to match(retired_terms)

        get account_path(account)

        confirmation = css_select("main form[data-turbo-confirm]").map { |form| form["data-turbo-confirm"] }.find { |text| text.start_with?("Un-file") }
        expect(confirmation).to eq("Un-file this bank transaction? This deletes the records it was filed as.")
        expect(confirmation).not_to match(retired_terms)
      end

      it "uses the same words for what went wrong when a bank transaction is refused" do
        post bank_transaction_filing_path(loblaws_row), params: file_params(envelope_id: "", amount: "60", description: "")

        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_text).to include("Envelope can't be blank", "Description can't be blank")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)

        post bank_transaction_filing_path(loblaws_row), params: file_params(amount: "60")

        expect(visible_text).to include("The records add up to $60.00, which is $22.45 less than the bank transaction's $82.45.")
        expect(visible_text).not_to match(retired_terms)

        post bank_transaction_filing_path(loblaws_row), params: file_params(kind: "deposit")

        expect(visible_text).to include("Kind must be Spend, since the money went out")

        post bank_transaction_filing_path(paycheck_row), params: file_params(kind: "spend", amount: "2800")

        expect(visible_text).to include("Kind must be Deposit or Refund, since the money came in")
        expect(visible_text).not_to match(retired_terms)
      end

      it "uses the same words for what was done, and what can't be" do
        post bank_transaction_filing_path(loblaws_row), params: file_params
        follow_redirect!
        expect(visible_text).to include("Bank transaction filed.")

        post bank_transaction_filing_path(loblaws_row), params: file_params
        follow_redirect!
        expect(visible_text).to include("This bank transaction is already filed.")

        post bank_transaction_ignore_path(loblaws_row)
        follow_redirect!
        expect(visible_text).to include("This bank transaction is filed. Un-file it before ignoring it.")

        delete bank_transaction_filing_path(loblaws_row)
        follow_redirect!
        expect(visible_text).to include("Bank transaction unfiled.")

        post bank_transaction_ignore_path(loblaws_row)
        follow_redirect!
        expect(visible_text).to include("Bank transaction ignored.")

        get new_bank_transaction_filing_path(loblaws_row)
        follow_redirect!
        expect(visible_text).to include("This bank transaction is ignored. Un-ignore it first.")

        delete bank_transaction_ignore_path(loblaws_row)
        follow_redirect!
        expect(visible_text).to include("Bank transaction un-ignored.")
        expect(visible_text).not_to match(retired_terms)
      end

      it "counts the records an Undo deletes in the confirmation, by kind, in the same words" do
        post bank_transaction_filing_path(loblaws_row), params: file_params

        get import_path(import)

        confirmation = css_select("main form[data-turbo-confirm]").map { |form| form["data-turbo-confirm"] }.sole
        expect(confirmation).to eq("Undo the Import of sept.csv? This deletes its 2 bank transactions and the 1 Spend filed from them.")
        expect(confirmation).not_to match(retired_terms)
      end
    end

    describe "Undo" do
      def confirmation
        css_select("main form[data-turbo-confirm]").map { |form| form["data-turbo-confirm"] }.sole
      end

      it "says Undo on the summary and on the Account's page, with a confirmation that lists what it deletes in the same words" do
        [ import_path(import), account_path(account) ].each do |path|
          get path

          assert_select "main button", text: "Undo"
          expect(confirmation).to eq("Undo the Import of sept.csv? This deletes its 2 bank transactions.")
          expect(confirmation).not_to match(retired_terms)
        end

        get import_path(import)

        expect(visible_text).to include("You can undo this Import until")
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)
      end

      it "uses the same words when it's refused, because the 24 hours are up or a newer Import is there" do
        travel_to(25.hours.from_now) do
          delete import_path(import)
          follow_redirect!

          expect(visible_text).to include("This Import ran more than 24 hours ago, so it can't be undone.")
          expect(visible_text).not_to match(retired_terms)
        end

        newer = nil
        travel_to(1.hour.from_now) { newer = account.imports.build(csv_format: import.csv_format, file_name: "newer.csv").tap { |i| i.run("2026-10-04,Gym,-30.00\n") } }
        delete import_path(import)
        follow_redirect!

        expect(visible_text).to include("This Import can't be undone while a newer Import is in this account. Undo that one first.")
        expect(visible_text).not_to match(retired_terms)
        expect(newer).to be_persisted
      end

      it "says Import undone when it works" do
        delete import_path(import)
        follow_redirect!

        expect(visible_text).to include("Import undone.")
      end
    end

    it "uses the same words for what went wrong when a file is refused" do
      post account_imports_path(account), params: { import: { csv_format_id: "", file: Rack::Test::UploadedFile.new(StringIO.new("2026-13-45,Paycheck,2800.00\n"), "text/csv", original_filename: "bad.csv") } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("CSV format can't be blank")

      csv_format_id = Budget::CsvFormat.find_by!(name: "Plain").id
      post account_imports_path(account), params: { import: { csv_format_id: csv_format_id, file: Rack::Test::UploadedFile.new(StringIO.new("2026-13-45,Paycheck,2800.00\n"), "text/csv", original_filename: "bad.csv") } }

      expect(visible_text).to include("Line 1: the date \"2026-13-45\" isn't a date in the YYYY-MM-DD format.")
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)

      post account_imports_path(account), params: { import: { csv_format_id: csv_format_id } }

      expect(visible_text).to include("Choose a file to import.")
    end

    it "uses the same words for what went wrong when an Account is refused" do
      post accounts_path, params: { account: { name: "" } }

      expect(visible_text).to include("Name can't be blank")
      expect(visible_text).not_to match(/\w+_\w+/)
    end

    it "uses the same words when an Account with bank transactions can't be deleted, and when a CSV format an Import used can't be" do
      delete account_path(account)
      follow_redirect!

      expect(visible_text).to include("This account can't be deleted because it has bank transactions.")
      expect(visible_text).not_to match(retired_terms)

      delete csv_format_path(import.csv_format)
      follow_redirect!

      expect(visible_text).to include("This CSV format can't be deleted because an Import used it.")
      expect(visible_text).not_to match(retired_terms)
    end
  end

  describe "CSV formats" do
    # A sample sent with the form, which a preview reads without Turbo, so the whole page comes back to be read.
    def preview(text, **choices)
      sample = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "sample.csv")
      format = { rows_to_skip: "1", date_column: "1", date_format: "YYYY-MM-DD", description_columns: "2", amount_style: "signed", amount_column: "3" }
      post csv_format_preview_path, params: { csv_format: format.merge(choices).merge(sample: sample) }
    end

    it "says what a CSV format reads in the words a person uses, with no column names" do
      get csv_formats_path

      expect(response.body).not_to match(/budget_/)
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).to include("CIBC", "Date in column 1 as YYYY-MM-DD. Description in columns 2 and 1. Amount in column 3, with money out as a negative amount.")
    end

    it "uses the same words for what went wrong when a CSV format is refused" do
      post csv_formats_path, params: { csv_format: { name: "", rows_to_skip: "-1", date_column: "", date_format: "", description_columns: "", amount_style: "direction", direction_column: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("Name can't be blank", "Rows to skip must be greater than or equal to 0", "Sample file must be chosen, so the columns can be read from it",
        "Date column can't be blank", "Date format must be chosen", "Description columns can't be blank", "Direction column can't be blank", "Direction for money in can't be blank")
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)
    end

    it "uses the same words in the preview of how a sample reads" do
      preview "Date,Description,Amount\n2026-10-01,Paycheck,2800.00\n2026-10-02,Loblaws,-82.45\n2026-10-03,Interest,0.00\n"

      expect(response).to have_http_status(:ok)
      expect(visible_text).to include("Sample", "Preview", "Skipped", "Oct 1, 2026", "Paycheck", "Money in", "Money out", "2 rows. 1 row of 0 would be skipped.")
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)
    end

    it "uses the same words for the row a file would be refused for, and what's still to choose" do
      preview "Date,Description,Amount\n13/45/2026,Paycheck,2800.00\n"

      expect(visible_text).to include("This file would be refused. Line 2: the date \"13/45/2026\" isn't a date in the YYYY-MM-DD format.")
      expect(visible_text).not_to match(retired_terms)

      preview "Date,Description,Amount\n2026-10-01,Paycheck,2800.00\n", date_format: "", amount_column: ""

      expect(visible_text).to include("Finish choosing", "Date format must be chosen", "Amount column can't be blank")
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)
    end
  end

  it "uses the same words for what went wrong when an Assigned amount is refused" do
    patch month_envelope_assignment_path("2026-10", bills), params: { assignment: { amount: "1.005" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(visible_text).to include("Assigned can't have more than 2 decimal places")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end

  it "uses the same words when more is assigned than was deposited" do
    assignments.first.update!(amount: 5000)

    get month_path("2026-10")

    expect(visible_text).to include("Ready to Assign -$2,001.50")
    expect(visible_text).to include("More was assigned than deposited.")
    expect(visible_text).to include("Carried over -$5.00 Deposited $3,000.00 Assigned $5,000.00 Reallocated $3.50")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end

  describe "the Ready to Assign card's four states" do
    def card_text
      Nokogiri::HTML(response.body).at("#ready-to-assign").text.squish
    end

    it "says money is left to assign" do
      get month_path("2026-10")

      expect(card_text).to include("Ready to Assign $2,958.50 left to assign")
      expect(card_text).to include("See Deposits")
      expect(card_text).not_to match(/\w+_\w+/)
      expect(card_text).not_to match(retired_terms)
    end

    it "says everything is assigned" do
      assignments.first.update!(amount: "2998.50")

      get month_path("2026-10")

      expect(card_text).to include("Ready to Assign $0.00 All assigned")
      expect(card_text).not_to match(/\w+_\w+/)
      expect(card_text).not_to match(retired_terms)
    end

    it "says more was assigned than deposited" do
      assignments.first.update!(amount: 5000)

      get month_path("2026-10")

      expect(card_text).to include("Ready to Assign -$2,001.50 More was assigned than deposited.")
      expect(card_text).not_to match(retired_terms)
    end

    it "says there is nothing to assign yet, and offers a New deposit" do
      get month_path("2026-08")

      expect(card_text).to include("Ready to Assign $0.00 Nothing to assign yet. New deposit")
      expect(card_text).not_to match(/\w+_\w+/)
      expect(card_text).not_to match(retired_terms)
    end
  end

  it "uses the same words when an envelope with records can't be deleted" do
    delete envelope_path(bills), params: { month: "2026-10" }
    follow_redirect!

    expect(visible_text).to include("This envelope can't be deleted because it has records.")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end

  it "uses the same words for what went wrong when a Spend is refused" do
    post spends_path, params: { spend: { envelope_id: "", description: "", date: "2026-10-15", amount: "1.005" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(visible_text).to include("Envelope can't be blank", "Description can't be blank", "Amount can't have more than 2 decimal places")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end

  it "says Spent, and Spends, on the pages where money paid out of an envelope is shown" do
    get month_envelope_path("2026-10", bills)

    expect(visible_text).to include("Spent $65.50", "Spends", "Hydro")

    get month_path("2026-10")

    expect(visible_text).to include("Spent")
    expect(visible_text).to include("New spend")
  end

  it "uses the same words for what went wrong when a Refund is refused" do
    post refunds_path, params: { refund: { envelope_id: "", description: "", date: "2026-10-15", amount: "1.005" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(visible_text).to include("Envelope can't be blank", "Description can't be blank", "Amount can't have more than 2 decimal places")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end

  it "says Refunded, and Refunds, on the pages where money that came back to an envelope is shown" do
    get month_envelope_path("2026-10", bills)

    expect(visible_text).to include("Refunded $12.25", "Refunds", "Hydro rebate", "New refund")

    get month_path("2026-10")

    expect(visible_text).to include("Refunded")
  end

  it "uses the same words for what went wrong when a Reallocation is refused" do
    post reallocations_path, params: { reallocation: { from_envelope_id: bills.id, to_envelope_id: bills.id, description: "", date: "2026-10-15", amount: "1.005" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(visible_text).to include("To can't be the same envelope as From", "Description can't be blank", "Amount can't have more than 2 decimal places")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)

    post reallocations_path, params: { reallocation: { from_envelope_id: "", to_envelope_id: "", description: "Gas", date: "2026-10-15", amount: "5" } }

    expect(visible_text).to include("From can't be blank", "To can't be blank")
    expect(visible_text).not_to match(/\w+_\w+/)
  end

  it "says Reallocated, and Reallocations, on the pages where money moved between envelopes is shown" do
    get month_envelope_path("2026-10", bills)

    expect(visible_text).to include("Reallocated -$12.25", "Reallocations", "Covering the gas", "To Fuel", "Reallocate")

    get month_path("2026-10")

    expect(visible_text).to include("Reallocated")
    expect(visible_text).not_to include("Reallocate ")
  end

  it "says Ready to Assign, and Reallocations, where money moved out of an envelope into it is shown, spelling it nowhere with underscores" do
    get new_reallocation_path(month: "2026-10", from: "envelope", envelope: bills.id)

    expect(css_select("select[name='reallocation[to_envelope_id]'] option").map { |option| option.text.strip }).to include("Ready to Assign")
    expect(response.body).not_to match(/ready_to_assign/)

    get edit_ready_to_assign_reallocation_path(to_ready_to_assign, month: "2026-10", from: "deposits")

    expect(visible_text).to include("Edit reallocation", "From", "To Ready to Assign")
    expect(response.body).not_to match(/ready_to_assign/)

    get month_deposits_path("2026-10")

    expect(visible_text).to include("Reallocations", "Unspent gas money", "From Bills", "Back to the pool", "$3.50")

    get month_envelope_path("2026-10", bills)

    expect(visible_text).to include("Reallocations", "Unspent gas money", "To Ready to Assign", "-$3.50")
  end

  it "says Reallocated on the Ready to Assign card, only when a Reallocation to it has been made" do
    get month_path("2026-10")

    expect(visible_text).to include("Reallocated $3.50")

    get month_path("2026-09")

    expect(visible_text).not_to include("Reallocated $")
  end

  it "uses the same words for what went wrong when a Reallocation to Ready to Assign is refused" do
    post reallocations_path, params: { reallocation: { from_envelope_id: "", to_envelope_id: Reallocating::READY_TO_ASSIGN, description: "", date: "2026-10-15", amount: "1.005" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(visible_text).to include("From can't be blank", "Description can't be blank", "Amount can't have more than 2 decimal places")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end

  it "uses the same words for what went wrong when a Deposit is refused" do
    post deposits_path, params: { deposit: { description: "", date: "2026-10-15", month: "2026-09-01", amount: "1.005" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(visible_text).to include("Ready to Assign in must be October 2026 or November 2026")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end

  describe "archived envelopes" do
    let!(:old_gym) { create(:budget_envelope, budget: budget, name: "Old gym") }

    before do
      travel_to Time.utc(2026, 10, 15, 16)
      create(:budget_assignment, envelope: old_gym, month: Date.new(2026, 9, 1), amount: 40)
      create(:budget_spend, envelope: old_gym, date: Date.new(2026, 9, 14), amount: 40)
      old_gym.update_column(:archived_at, Time.current)
    end

    # What went wrong, as the alert on the envelope's page says it.
    def alert_after_archiving(envelope)
      post envelope_archive_path(envelope), params: { month: "2026-10" }
      follow_redirect!
      css_select("[role=alert]").map { |alert| alert.text.squish }.sole
    end

    it "says Archived on the badge, Archived envelopes on the section, and Unarchive on the envelope's page, with no snake_case or retired terms" do
      [ month_path("2026-09"), month_path("2026-10"), month_envelope_path("2026-09", old_gym) ].each do |path|
        get path

        expect(response).to have_http_status(:ok)
        expect(visible_text).not_to match(/\w+_\w+/)
        expect(visible_text).not_to match(retired_terms)
        expect(response.body).not_to match(/archived_at/)
      end

      get month_path("2026-09")
      expect(visible_text).to include("Old gym Archived", "Archived envelopes")

      get month_envelope_path("2026-09", old_gym)
      expect(visible_text).to include("Old gym Archived", "Unarchive")
    end

    it "says All your envelopes are archived when none is in use and none has figures this month" do
      # Everything but the archived envelope's own history is cleared, and its figures are all last month's.
      envelopes = budget.envelopes
      Budget::Assignment.where(envelope: envelopes).where.not(envelope: old_gym).delete_all
      Budget::Spend.where(envelope: envelopes).where.not(envelope: old_gym).delete_all
      Budget::Refund.where(envelope: envelopes).delete_all
      Budget::EnvelopeReallocation.involving(envelopes).delete_all
      Budget::ReadyToAssignReallocation.where(envelope: envelopes).delete_all
      envelopes.update_all(archived_at: Time.current, starting_balance: 0)

      get month_path("2026-12")

      expect(visible_text).to include("All your envelopes are archived.", "New envelope", "Archived envelopes")
      expect(visible_text).not_to include("You don't have any envelopes yet.")
      expect(visible_text).not_to match(/\w+_\w+/)
    end

    it "uses the same words for the three reasons archiving is refused" do
      trip = create(:budget_envelope, budget: budget, name: "Trip")
      assignment = create(:budget_assignment, envelope: trip, month: Date.new(2026, 10, 1), amount: 100)
      expect(alert_after_archiving(trip)).to eq("Available is $100.00 in October 2026. Lower this month's Assigned, spend it or reallocate it first.")

      assignment.destroy!
      create(:budget_spend, envelope: trip, date: Date.new(2026, 10, 3), amount: 25)
      expect(alert_after_archiving(trip)).to eq("Available is -$25.00 in October 2026. Assign more to it or reallocate money to it first.")

      Budget::Spend.where(envelope: trip).delete_all
      create(:budget_assignment, envelope: trip, month: Date.new(2026, 11, 1), amount: 5)
      expect(alert_after_archiving(trip)).to eq("It has Assigned, Spends, Refunds or Reallocations after October 2026. Clear them first.")
    end

    it "uses the same words for what went wrong when a Spend is put in an archived envelope" do
      post spends_path, params: { spend: { envelope_id: old_gym.id, description: "Towels", date: "2026-10-15", amount: "5" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("Envelope is archived")
    end

    it "uses the same words for what went wrong when an archived envelope's Assigned is changed" do
      patch month_envelope_assignment_path("2026-09", old_gym), params: { assignment: { amount: "5" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("Old gym is archived, so its Assigned can't be changed. Unarchive it first.")
      expect(visible_text).not_to match(retired_terms)
    end

    it "uses the same words for what went wrong when an archived envelope's name is used again" do
      post envelopes_path, params: { envelope: { name: "Old gym" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("Name is already used by an archived envelope. Unarchive it or choose another name.")
      expect(visible_text).not_to match(/\w+_\w+/)
      expect(visible_text).not_to match(retired_terms)
    end
  end
end
