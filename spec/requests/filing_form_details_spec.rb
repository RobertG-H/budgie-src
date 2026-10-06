require "rails_helper"

# The filing form is the envelope first: choosing it, maybe ticking "Always file like this", and File are all that's on screen, and what's
# rarely changed (the description, date, amount, a Deposit's month and notes, and the Filing rule's text) is under a closed <details> that opens
# itself whenever something in it needs attention, so nothing that matters is left in a closed section.
RSpec.describe "The filing form's Edit details and Edit rule", type: :request do
  include FilingHistory

  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }
  let!(:money_out) { create(:budget_bank_transaction, account: account, description: "COSTCO #123", date: Date.new(2026, 9, 12), amount: -100) }
  let!(:money_in) { create(:budget_bank_transaction, account: account, description: "ACME PAYROLL", date: Date.new(2026, 9, 30), amount: 3000) }

  before { sign_in_as budget.user }

  def record_params(**attributes)
    { kind: "spend", envelope_id: groceries.id, description: "COSTCO #123", date: "2026-09-12", amount: "100", notes: "" }.merge(attributes)
  end

  def file(bank_transaction = money_out, records: [ record_params ], rule: nil)
    filing = { records: records.each_with_index.to_h { |record, index| [ index.to_s, record ] } }
    filing[:rule] = rule if rule
    post bank_transaction_filing_path(bank_transaction), params: { filing: filing }
  end

  # The "Edit details" of the record at `index`.
  def details_of(index = 0)
    css_select("[data-filing-split-target=records] > fieldset")[index].css("details").find { |details| details.at("summary").text.include?("Edit details") }
  end

  # Whether a <details> is open, which is an attribute that has no value.
  def open?(details)
    details.key?("open")
  end

  def edit_rule
    css_select("details").find { |details| details.at("summary").text.squish == "Edit rule" }
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  describe "the form for one record" do
    it "has the envelope, Always file like this and File in view, and a closed Edit details holding everything else" do
      get new_bank_transaction_filing_path(money_out)

      expect(details_of).to be_present
      expect(open?(details_of)).to be(false)
      expect(details_of.at("summary").text.squish).to start_with("Edit details")
      %w[ description date amount notes ].each do |field|
        expect(details_of.css("[name='filing[records][0][#{field}]']")).to be_present, "#{field} should be inside Edit details"
      end
      assert_select "select[name='filing[records][0][envelope_id]']"
      assert_select "input[type=checkbox][name='filing[rule][make]'][checked]"
      expect(css_select("[data-filing-split-target=records] > fieldset").first.css("details").map { |d| d.css("select[name$='[envelope_id]']").size }.sum).to eq(0)
      assert_select "input[type=submit][value=File]"
    end

    it "shows what's in Edit details in its summary, so closing it isn't a mystery" do
      get new_bank_transaction_filing_path(money_out)

      expect(details_of.at("summary").text.squish).to eq("Edit details COSTCO #123 · Sep 12, 2026 · $100.00")
    end

    it "puts the month choice of a Deposit in Edit details too" do
      get new_bank_transaction_filing_path(money_in)

      expect(details_of.css("input[type=radio][name='filing[records][0][month]']").size).to eq(2)
      expect(details_of.at("summary").text.squish).to eq("Edit details ACME PAYROLL · Sep 30, 2026 · $3,000.00")
      assert_select "input[type=radio][name='filing[records][0][kind]']", count: 2
    end

    it "puts Always file like this before Edit details, with Edit rule closed under it and a sentence of what it would do" do
      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).to include("Chequing bank transactions with 'costco' in their description are filed the same way as they come in.")
      expect(edit_rule).to be_present
      expect(open?(edit_rule)).to be(false)
      expect(edit_rule.css("input[type=text][name='filing[rule][text]']")).to be_present
      expect(edit_rule.css("turbo-frame#filing-rule-preview")).to be_present
      # The box itself and the sentence are outside Edit rule.
      expect(edit_rule.css("input[type=checkbox][name='filing[rule][make]']")).to be_empty
      positions = response.body.enum_for(:scan, /Always file like this|Edit rule|Edit details/).map { Regexp.last_match[0] }
      expect(positions.first(3)).to eq([ "Always file like this", "Edit rule", "Edit details" ])
    end

    it "autofocuses the Envelope select when it's empty, and never a field inside Edit details" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "select[name='filing[records][0][envelope_id]'][autofocus]"
      assert_select "input[type=submit][autofocus]", count: 0
      expect(css_select("details [autofocus]")).to be_empty
    end

    it "autofocuses File when no envelope is empty: a Deposit has none, and a Guess has chosen one" do
      get new_bank_transaction_filing_path(money_in)

      assert_select "input[type=submit][value=File][autofocus]"
      assert_select "select[autofocus]", count: 0
      expect(css_select("details [autofocus]")).to be_empty
    end

    it "autofocuses File when the envelope is already chosen" do
      file records: [ record_params(amount: "60") ]

      assert_select "input[type=submit][value=File][autofocus]"
      assert_select "select[autofocus]", count: 0
    end

    it "autofocuses the envelope of the first record that still has none in a split that comes back, and File when every record has one" do
      file records: [ record_params(amount: "60"), record_params(envelope_id: "", amount: "30") ]

      assert_select "[data-filing-split-target=records] > fieldset:nth-of-type(2) select[autofocus]"
      assert_select "[data-filing-split-target=records] > fieldset:nth-of-type(1) select[autofocus]", count: 0
      assert_select "input[type=submit][autofocus]", count: 0

      file records: [ record_params(amount: "60"), record_params(envelope_id: household.id, amount: "30") ]

      assert_select "select[autofocus]", count: 0
      assert_select "input[type=submit][value=File][autofocus]"
    end

    it "wires Edit details to the filing-details controller, which keeps the summary and opens it on an invalid field" do
      get new_bank_transaction_filing_path(money_out)

      assert_select "[data-controller~=filing-details][data-filing-details-unit-value='$']"
      assert_select "[data-filing-details-target=summary]"
      assert_select "details[data-filing-split-target=details]"
    end
  end

  describe "when Edit details opens itself" do
    it "stays closed for a Guess, which changes only the kind and the envelope" do
      filed("COSTCO #12", groceries)

      get new_bank_transaction_filing_path(money_out)

      expect(visible_text).to include("Guess: like COSTCO #12 → Groceries")
      assert_select "select[name='filing[records][0][envelope_id]'] option[selected]", text: "Groceries"
      expect(open?(details_of)).to be(false)
    end

    it "is open for every record of a split, and for the one a template adds" do
      file records: [ record_params(amount: "60"), record_params(envelope_id: household.id, amount: "30") ]

      expect(open?(details_of(0))).to be(true)
      expect(open?(details_of(1))).to be(true)

      get new_bank_transaction_filing_path(money_out)
      template = Nokogiri::HTML.fragment(css_select("template[data-filing-split-target=template]").first.inner_html)
      expect(open?(template.at("details"))).to be(true)
    end

    {
      "description" => [ { description: "" }, "Description can't be blank" ],
      "date" => [ { date: "" }, "Date can't be blank" ],
      "amount" => [ { amount: "1.005" }, "Amount can't have more than 2 decimal places" ]
    }.each do |field, (attributes, message)|
      it "is open when the #{field} has an error" do
        file records: [ record_params(**attributes) ]

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: message
        expect(open?(details_of)).to be(true)
      end
    end

    it "is open when a Deposit's month has an error" do
      file money_in, records: [ record_params(kind: "deposit", envelope_id: "", month: "2026-12-01", description: "ACME PAYROLL", date: "2026-09-30", amount: "3000") ]

      expect(response).to have_http_status(:unprocessable_content)
      expect(open?(details_of)).to be(true)
    end

    it "stays closed when the only error is outside it, such as the envelope" do
      file records: [ record_params(envelope_id: "") ]

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Envelope can't be blank"
      expect(open?(details_of)).to be(false)
    end

    {
      "description" => [ { description: "Costco run" }, "Costco run" ],
      "date" => [ { date: "2026-09-13" }, "Sep 13, 2026" ],
      "amount" => [ { amount: "90" }, "$90.00" ],
      "notes" => [ { notes: "Bulk buy" }, "COSTCO #123" ]
    }.each do |field, (attributes, shown)|
      it "is open when it comes back after a refusal with the #{field} changed from the bank's" do
        file records: [ record_params(envelope_id: "", **attributes) ]

        expect(response).to have_http_status(:unprocessable_content)
        expect(open?(details_of)).to be(true)
        expect(details_of.at("summary").text).to include(shown)
      end
    end

    it "is open when it comes back after a refusal with a Deposit's month changed from its date's" do
      file money_in, records: [ record_params(kind: "deposit", envelope_id: "", month: "2026-10-01", description: "ACME PAYROLL", date: "2026-09-30", amount: "3000") ],
        rule: { make: "1", text: "shell" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(open?(details_of)).to be(true)
      expect(details_of.at("summary").text.squish).to eq("Edit details ACME PAYROLL · Sep 30, 2026 · $3,000.00, counts toward October")
    end

    it "stays closed when it comes back after a refusal with nothing in it changed" do
      file records: [ record_params(envelope_id: "") ]

      expect(open?(details_of)).to be(false)
    end
  end

  describe "when Edit rule opens itself" do
    it "stays closed for a rule that's as offered" do
      get new_bank_transaction_filing_path(money_out)

      expect(open?(edit_rule)).to be(false)
    end

    it "is open when the text was changed, and the sentence says the text as it is" do
      file records: [ record_params(envelope_id: "") ], rule: { make: "1", text: "cost" }

      expect(open?(edit_rule)).to be(true)
      expect(visible_text).to include("Chequing bank transactions with 'cost' in their description", "Bank transactions in any account with 'cost' in their description")
    end

    it "stays closed when the only change to the text is a number or a symbol, which a rule ignores" do
      file records: [ record_params(envelope_id: "") ], rule: { make: "1", text: "COSTCO #4455 /" }

      expect(open?(edit_rule)).to be(false)
      expect(visible_text).to include("Chequing bank transactions with 'costco' in their description")
    end

    it "is open when the rule has an error, such as text that isn't part of the description" do
      file rule: { make: "1", text: "shell" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: /Text must be part of the bank transaction's description/
      expect(open?(edit_rule)).to be(true)
    end

    it "is open when it would update a Filing rule that's there, which needs saying" do
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "costco #123", account: account)

      get new_bank_transaction_filing_path(money_out)

      expect(open?(edit_rule)).to be(true)
      expect(visible_text).to include("Updates the Filing rule for 'costco' in Chequing, which files them as Spend from Groceries now.")
    end
  end

  describe "a split" do
    it "shows every field of every record, and no Always file like this" do
      file records: [ record_params(amount: "60"), record_params(envelope_id: household.id, amount: "30") ]

      %w[ description date amount notes ].each do |field|
        expect(details_of(0).css("[name='filing[records][0][#{field}]']")).to be_present
        expect(details_of(1).css("[name='filing[records][1][#{field}]']")).to be_present
      end
      expect(open?(details_of(1))).to be(true)
    end

    it "has a place in each record for the rule to sit in, which the first record has filled" do
      get new_bank_transaction_filing_path(money_out)

      slots = css_select("[data-filing-split-target=ruleSlot]")
      expect(slots.size).to eq(2)
      expect(slots.first.at("[data-filing-split-target=rule]")).to be_present
      expect(slots.last.children).to be_empty
    end
  end
end
