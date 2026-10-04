require "rails_helper"

RSpec.describe "Deposits", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }

  # A Deposit counting toward `month` (the month of its date unless given another) in the budget.
  def deposit(description, date, amount: 100, month: date, notes: "", budget: self.budget)
    create(:budget_deposit, budget: budget, description: description, date: date, month: month, amount: amount, notes: notes)
  end

  # What each listed Deposit shows, as one line of text apiece.
  def rows
    css_select("ul.list li").map { |row| row.text.squish }
  end

  before { sign_in_as budget.user }

  describe "GET /months/:month/deposits" do
    it "is headed Deposits, with the month as its description and New deposit as its action" do
      get month_deposits_path("2026-09")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Deposits · September 2026 · Budgie"
      assert_select "h1", text: "Deposits"
      assert_select "h1 + p", text: "September 2026"
      assert_select "a.btn.btn-primary[href='#{new_deposit_path(month: "2026-09", from: "deposits")}']", text: "New deposit"
    end

    it "has month links that stay on Deposits, and a link back to the month view" do
      travel_to Time.utc(2026, 9, 15, 16)

      get month_deposits_path("2026-09")

      assert_select "nav[aria-label=Months] a[href='#{month_deposits_path("2026-08")}']", text: "August 2026"
      assert_select "nav[aria-label=Months] a[href='#{month_deposits_path("2026-10")}']", text: "October 2026"
      assert_select "a", text: "This month", count: 0
      assert_select "a[href='#{month_path("2026-09")}']", text: "Back to September 2026"

      get month_deposits_path("2027-03")

      assert_select "nav[aria-label=Months] a[href='#{month_deposits_path("2026-09")}']", text: "This month"
      assert_select "a[href='#{month_path("2027-03")}']", text: "Back to March 2027"
    end

    it "shows the month's Deposited total" do
      deposit "Paycheck", Date.new(2026, 9, 1), amount: 3000
      deposit "Gift", Date.new(2026, 9, 12), amount: 250.5
      deposit "Last month's", Date.new(2026, 8, 1), amount: 999

      get month_deposits_path("2026-09")

      assert_select ".stat-title", text: "Deposited"
      assert_select ".stat-value", text: "$3,250.50"
    end

    it "lists exactly the Deposits for the month, including one dated the month before and marked for it" do
      deposit "Dated in September", Date.new(2026, 9, 3)
      deposit "Dated in August, for September", Date.new(2026, 8, 31), month: Date.new(2026, 9, 1)
      deposit "Dated in September, for October", Date.new(2026, 9, 30), month: Date.new(2026, 10, 1)
      deposit "Dated in August", Date.new(2026, 8, 5)

      get month_deposits_path("2026-09")

      expect(rows).to eq([ "Sep 3 Dated in September $100.00", "Aug 31 Dated in August, for September $100.00" ])

      get month_deposits_path("2026-10")

      expect(rows).to eq([ "Sep 30 Dated in September, for October $100.00" ])
    end

    it "lists the newest date first, and the most recently entered first within a date" do
      deposit "Oldest", Date.new(2026, 9, 1)
      deposit "Latest entered", Date.new(2026, 9, 20)
      # Saved last, but entered an hour before the other Deposit dated September 20.
      create(:budget_deposit, budget: budget, description: "Entered first", date: Date.new(2026, 9, 20), created_at: 1.hour.ago)

      get month_deposits_path("2026-09")

      expect(rows).to eq([ "Sep 20 Latest entered $100.00", "Sep 20 Entered first $100.00", "Sep 1 Oldest $100.00" ])
    end

    it "shows each Deposit's date, description, notes and amount, linking to where it's edited" do
      paycheck = deposit "Paycheck", Date.new(2026, 9, 30), amount: 3000, notes: "Biweekly, from Acme"
      bare = deposit "Gift", Date.new(2026, 9, 5), amount: 25.5

      get month_deposits_path("2026-09")

      assert_select "ul.list li a[href='#{edit_deposit_path(paycheck, month: "2026-09", from: "deposits")}']" do
        assert_select "span", text: "Sep 30"
        assert_select "span", text: "Paycheck"
        assert_select "span[class~='text-base-content/70']", text: "Biweekly, from Acme"
        assert_select "span.text-right", text: "$3,000.00"
      end
      assert_select "ul.list li a[href='#{edit_deposit_path(bare, month: "2026-09", from: "deposits")}']" do
        assert_select "span", text: "Sep 5"
        assert_select "span.text-right", text: "$25.50"
        assert_select "span.block[class~='text-base-content/70']", count: 0
      end
    end

    it "says when there are none" do
      get month_deposits_path("2026-09")

      assert_select "ul.list", count: 0
      assert_select "main p", text: "No deposits in September 2026."
      assert_select ".stat-value", text: "$0.00"
    end

    it "doesn't list anyone else's Deposits" do
      deposit "Mine", Date.new(2026, 9, 1), amount: 10
      deposit "Someone else's", Date.new(2026, 9, 1), amount: 5000, budget: create(:budget)

      get month_deposits_path("2026-09")

      assert_select "ul.list li", count: 1
      assert_select ".stat-value", text: "$10.00"
      expect(response.body).not_to include("Someone else")
    end

    it "is not found for something that isn't a month" do
      get "/months/2026-13/deposits"

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get month_deposits_path("2026-09")

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "GET /deposits/new" do
    before { travel_to Time.utc(2026, 9, 15, 16) }

    it "shows a form with a field for everything a Deposit has" do
      get new_deposit_path(month: "2026-09", from: "month")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "New deposit · Budgie"
      assert_select "h1", text: "New deposit"
      assert_select "form[action='#{deposits_path}'][method=post]" do
        assert_select "label", text: "Description"
        assert_select "input[type=text][name='deposit[description]'][required]"
        assert_select "p", text: "Such as Paycheck"
        assert_select "label", text: "Date"
        assert_select "input[type=date][name='deposit[date]'][required]"
        assert_select "legend", text: "Ready to Assign in"
        assert_select "label", text: "Amount"
        assert_select "input[type=number][name='deposit[amount]'][step='0.01'][required]"
        assert_select "label", text: "Notes"
        assert_select "textarea[name='deposit[notes]']:not([required])"
        assert_select "input[type=submit]"
      end
    end

    it "starts with today's date when today is in the month it was opened from" do
      get new_deposit_path(month: "2026-09")

      assert_select "input[name='deposit[date]'][value='2026-09-15']"
    end

    it "starts with the 1st of the month it was opened from when today isn't in it" do
      get new_deposit_path(month: "2027-03")

      assert_select "input[name='deposit[date]'][value='2027-03-01']"
    end

    it "starts with today's date when it wasn't opened from a month" do
      get new_deposit_path

      assert_select "input[name='deposit[date]'][value='2026-09-15']"
    end

    it "offers the month of the date and the month after, and starts on the month of the date" do
      get new_deposit_path(month: "2027-03")

      assert_select "fieldset" do
        assert_select "label:nth-of-type(1) input[type=radio][name='deposit[month]'][value='2027-03-01'][checked][required]"
        assert_select "label:nth-of-type(1)", text: "March 2027"
        assert_select "label:nth-of-type(2) input[type=radio][name='deposit[month]'][value='2027-04-01'][required]:not([checked])"
        assert_select "label:nth-of-type(2)", text: "April 2027"
      end
    end

    it "carries the page and month it was opened from, so saving can go back" do
      get new_deposit_path(month: "2026-09", from: "deposits")

      assert_select "form input[type=hidden][name=from][value=deposits]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
    end

    it "has a Cancel link back to the page it was opened from" do
      get new_deposit_path(month: "2026-09", from: "deposits")
      assert_select "a.btn[href='#{month_deposits_path("2026-09")}']", text: "Cancel"

      get new_deposit_path(month: "2026-09", from: "month")
      assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
    end

    it "goes back to the month view when it isn't told where it was opened from, or is told something else" do
      [ nil, "", "nowhere", "https://evil.example/", "//evil.example", "month/../../evil" ].each do |from|
        get new_deposit_path(month: "2026-09", from: from)

        assert_select "a.btn[href='#{month_path("2026-09")}']", text: "Cancel"
        assert_select "form input[type=hidden][name=from]", count: 0
        expect(response.body).not_to include("evil")
      end
    end

    it "is not found for a month that isn't one" do
      get new_deposit_path(month: "2026-13")

      expect(response).to have_http_status(:not_found)
    end

    it "is wired to keep the month choices in step with the date" do
      get new_deposit_path(month: "2026-09")

      assert_select "form[data-controller=month-choice]" do
        assert_select "input[type=date][data-month-choice-target=date][data-action='input->month-choice#update']"
        assert_select "input[type=radio][data-month-choice-target=radio]", count: 2
        assert_select "span[data-month-choice-target=name]", count: 2
      end
    end
  end

  describe "POST /deposits" do
    let(:deposit_params) { { description: "Paycheck", date: "2026-09-15", month: "2026-09-01", amount: "3000", notes: "Biweekly" } }

    it "adds a Deposit to the user's budget" do
      expect { post deposits_path, params: { deposit: deposit_params, from: "month", month: "2026-09" } }
        .to change(budget.deposits, :count).by(1)

      expect(budget.deposits.sole).to have_attributes(
        description: "Paycheck", date: Date.new(2026, 9, 15), month: Date.new(2026, 9, 1), amount: BigDecimal("3000"), notes: "Biweekly"
      )
      expect(response).to redirect_to(month_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Deposit added."
    end

    it "counts toward the month of its date unless it's marked for the month after" do
      post deposits_path, params: { deposit: deposit_params.except(:month), from: "month", month: "2026-09" }

      expect(budget.deposits.sole.month).to eq(Date.new(2026, 9, 1))
    end

    it "goes to the month it counts toward, which can be the month after its date" do
      post deposits_path, params: { deposit: deposit_params.merge(date: "2026-09-30", month: "2026-10-01"), from: "month", month: "2026-09" }

      expect(budget.deposits.sole).to have_attributes(date: Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))
      expect(response).to redirect_to(month_path("2026-10"))
    end

    it "goes back to a month's Deposits when it was opened from there, for the month it counts toward" do
      post deposits_path, params: { deposit: deposit_params.merge(date: "2026-09-30", month: "2026-10-01"), from: "deposits", month: "2026-09" }

      expect(response).to redirect_to(month_deposits_path("2026-10"))
    end

    it "goes to the month view when told to go anywhere else, or nowhere" do
      [ nil, "nowhere", "https://evil.example/", "//evil.example" ].each do |from|
        post deposits_path, params: { deposit: deposit_params, from: from, month: "2026-09" }

        expect(response).to redirect_to(month_path("2026-09"))
      end
    end

    it "saves blank notes as an empty string" do
      post deposits_path, params: { deposit: deposit_params.merge(notes: "") }

      expect(budget.deposits.sole.notes).to eq("")
    end

    it "shows what's wrong, and keeps what was typed, for an invalid Deposit" do
      params = { deposit: deposit_params.merge(description: " ", amount: "0", notes: "Keep me"), from: "deposits", month: "2026-09" }

      expect { post deposits_path, params: params }.not_to change(Budget::Deposit, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "textarea[name='deposit[notes]']", text: "Keep me"
      assert_select "input[name='deposit[date]'][value='2026-09-15']"
      assert_select "form input[type=hidden][name=from][value=deposits]"
      assert_select "form input[type=hidden][name=month][value='2026-09']"
      assert_select "a.btn[href='#{month_deposits_path("2026-09")}']", text: "Cancel"
    end

    it "refuses more than 2 decimal places instead of rounding" do
      post deposits_path, params: { deposit: deposit_params.merge(amount: "10.005") }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Amount can't have more than 2 decimal places"
    end

    it "refuses a month that doesn't fit the date, and offers the months that do" do
      post deposits_path, params: { deposit: deposit_params.merge(date: "2026-10-15", month: "2026-09-01") }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Ready to Assign in must be October 2026 or November 2026"
      assert_select "fieldset input[type=radio][value='2026-10-01']"
      assert_select "fieldset input[type=radio][value='2026-11-01']"
      assert_select "fieldset input[type=radio][checked]", count: 0
    end

    it "shows a missing date as an error, and still offers month choices" do
      post deposits_path, params: { deposit: deposit_params.merge(date: ""), month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Date can't be blank"
      assert_select "fieldset input[type=radio]", count: 2
    end

    it "ignores a budget_id in the params" do
      other_budget = create(:budget)

      post deposits_path, params: { deposit: deposit_params.merge(budget_id: other_budget.id) }

      expect(budget.deposits.count).to eq(1)
      expect(other_budget.deposits).to be_empty
    end

    it "is not found when the month it was opened from isn't one" do
      expect { post deposits_path, params: { deposit: deposit_params, month: "2026-13" } }.not_to change(Budget::Deposit, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /deposits/:id/edit" do
    let(:paycheck) { deposit "Paycheck", Date.new(2026, 9, 30), amount: 3000, month: Date.new(2026, 10, 1), notes: "Biweekly" }

    it "shows the form for the user's Deposit, filled in" do
      get edit_deposit_path(paycheck, month: "2026-10", from: "deposits")

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit deposit · Budgie"
      assert_select "h1", text: "Edit deposit"
      assert_select "form[action='#{deposit_path(paycheck)}'][method=post]" do
        assert_select "input[name='_method'][value=patch]"
        assert_select "input[name='deposit[description]'][value=Paycheck]"
        assert_select "input[name='deposit[date]'][value='2026-09-30']"
        assert_select "input[type=radio][value='2026-09-01']:not([checked])"
        assert_select "input[type=radio][value='2026-10-01'][checked]"
        assert_select "textarea[name='deposit[notes]']", text: "Biweekly"
      end
      expect(BigDecimal(css_select("input[name='deposit[amount]']").first["value"])).to eq(3000)
    end

    it "offers to delete the Deposit, behind a confirmation, and remembers where the form was opened from" do
      get edit_deposit_path(paycheck, month: "2026-10", from: "deposits")

      assert_select "form[action='#{deposit_path(paycheck)}'][data-turbo-confirm='Delete the Paycheck deposit?']" do
        assert_select "input[name='_method'][value=delete]"
        assert_select "input[name=from][value=deposits]"
        assert_select "input[name=month][value='2026-10']"
        assert_select "button", text: "Delete"
      end
    end

    it "has a Cancel link back to the page it was opened from" do
      get edit_deposit_path(paycheck, month: "2026-10", from: "deposits")

      assert_select "a.btn[href='#{month_deposits_path("2026-10")}']", text: "Cancel"
    end

    it "is not found for another user's Deposit" do
      get edit_deposit_path(create(:budget_deposit))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /deposits/:id" do
    let(:paycheck) { deposit "Paycheck", Date.new(2026, 9, 15), amount: 3000 }

    it "updates the Deposit, and goes back to the page it was opened from" do
      patch deposit_path(paycheck), params: { deposit: { description: "Bonus", amount: "250.5", notes: "Spot award" }, from: "deposits", month: "2026-09" }

      expect(paycheck.reload).to have_attributes(description: "Bonus", amount: BigDecimal("250.5"), notes: "Spot award")
      expect(response).to redirect_to(month_deposits_path("2026-09"))
      follow_redirect!
      assert_select "[role=status]", text: "Deposit updated."
    end

    it "follows a changed date to the month the Deposit now counts toward, not the one the form was opened from" do
      patch deposit_path(paycheck), params: { deposit: { date: "2026-11-03", month: "2026-11-01" }, from: "deposits", month: "2026-09" }

      expect(paycheck.reload).to have_attributes(date: Date.new(2026, 11, 3), month: Date.new(2026, 11, 1))
      expect(response).to redirect_to(month_deposits_path("2026-11"))
    end

    it "can be marked for the month after, and goes there" do
      patch deposit_path(paycheck), params: { deposit: { month: "2026-10-01" }, from: "month", month: "2026-09" }

      expect(paycheck.reload.month).to eq(Date.new(2026, 10, 1))
      expect(response).to redirect_to(month_path("2026-10"))
    end

    it "goes to the month view when told to go anywhere else" do
      patch deposit_path(paycheck), params: { deposit: { description: "Bonus" }, from: "https://evil.example/", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "shows what's wrong, and keeps the form, for an invalid change" do
      patch deposit_path(paycheck), params: { deposit: { description: "", amount: "-5" }, from: "deposits", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Description can't be blank"
      assert_select "[role=alert] li", text: "Amount must be greater than 0"
      assert_select "form input[name=from][value=deposits]"
      assert_select "h1", text: "Edit deposit"
      expect(paycheck.reload).to have_attributes(description: "Paycheck", amount: 3000)
    end

    it "refuses a month that no longer fits a changed date" do
      patch deposit_path(paycheck), params: { deposit: { date: "2026-11-03" }, from: "month", month: "2026-09" }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Ready to Assign in must be November 2026 or December 2026"
      expect(paycheck.reload.date).to eq(Date.new(2026, 9, 15))
    end

    it "doesn't move the Deposit to another budget" do
      other_budget = create(:budget)

      patch deposit_path(paycheck), params: { deposit: { description: "Bonus", budget_id: other_budget.id } }

      expect(paycheck.reload.budget).to eq(budget)
    end

    it "is not found for another user's Deposit, which stays unchanged" do
      others = create(:budget_deposit, description: "Someone else's")

      patch deposit_path(others), params: { deposit: { description: "Mine now" } }

      expect(response).to have_http_status(:not_found)
      expect(others.reload.description).to eq("Someone else's")
    end
  end

  describe "DELETE /deposits/:id" do
    it "deletes the Deposit, and goes back for the month it counted toward" do
      paycheck = deposit "Paycheck", Date.new(2026, 9, 30), month: Date.new(2026, 10, 1)

      expect { delete deposit_path(paycheck), params: { from: "deposits", month: "2026-09" } }
        .to change(Budget::Deposit, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_deposits_path("2026-10"))
      follow_redirect!
      assert_select "[role=status]", text: "Deposit deleted."
    end

    it "goes to the month view when it isn't told where to go back to" do
      paycheck = deposit "Paycheck", Date.new(2026, 9, 15)

      delete deposit_path(paycheck)

      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "is not found for another user's Deposit, which isn't deleted" do
      others = create(:budget_deposit)

      expect { delete deposit_path(others) }.not_to change(Budget::Deposit, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
