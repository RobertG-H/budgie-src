require "rails_helper"

# The UI uses only the terms CLAUDE.md lists. Internal names (tables, columns) stay out of it, and so do the terms
# GLOSSARY.md says to avoid.
RSpec.describe "The words on the pages", type: :request do
  let(:retired_terms) do
    /\b(categor(y|ies)|income|inflow|outflow|budgeted|spending|expense|purchase|payment|transfer|move|reimbursement|repayment|wallet|transaction|payee|payer)\b/i
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

  before { sign_in_as budget.user }

  # What a person reads on the page, not its markup.
  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  {
    "the month view" => -> { month_path("2026-10") },
    "a month's Deposits" => -> { month_deposits_path("2026-10") },
    "the envelope page" => -> { month_envelope_path("2026-10", bills) },
    "the Assigned input" => -> { edit_month_envelope_assignment_path("2026-10", bills) }
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
    "the envelope form" => -> { new_envelope_path(month: "2026-10", from: "month") },
    "the envelope edit form" => -> { edit_envelope_path(bills, month: "2026-10", from: "envelope") },
    "the Assigned input" => -> { edit_month_envelope_assignment_path("2026-10", bills) }
  }.each do |page, path|
    it "has no snake_case names and no retired terms in the words on #{page}" do
      get instance_exec(&path)

      expect(response).to have_http_status(:ok)
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

    expect(visible_text).to include("Ready to Assign -$2,005.00")
    expect(visible_text).to include("More was assigned than deposited.")
    expect(visible_text).to include("Carried over -$5.00 · Deposited $3,000.00 · Assigned $5,000.00")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
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

  it "uses the same words for what went wrong when a Deposit is refused" do
    post deposits_path, params: { deposit: { description: "", date: "2026-10-15", month: "2026-09-01", amount: "1.005" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(visible_text).to include("Ready to Assign in must be October 2026 or November 2026")
    expect(visible_text).not_to match(/\w+_\w+/)
    expect(visible_text).not_to match(retired_terms)
  end
end
