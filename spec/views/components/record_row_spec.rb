require "rails_helper"

RSpec.describe "components/_record_row", type: :view do
  let(:budget) { Budget.new(currency: "CAD") }

  def render_row(**locals)
    locals = { href: "/deposits/7/edit", date: Date.new(2026, 9, 30), description: "Paycheck", amount: 3000, budget: budget }.merge(locals)
    render partial: "components/record_row", locals: locals
  end

  it "is one row of a list, linking to the record's edit page" do
    render_row

    assert_select "li a.list-row[href='/deposits/7/edit']", count: 1
  end

  it "shows the date as month and day, the description, and the amount in the budget's currency" do
    render_row

    assert_select "a.list-row" do
      assert_select "span", text: "Sep 30"
      assert_select "span", text: "Paycheck"
      assert_select "span.text-right.tabular-nums", text: "$3,000.00"
    end
  end

  it "doesn't pad single-digit days" do
    render_row date: Date.new(2026, 9, 5)

    assert_select "span", text: "Sep 5"
  end

  it "shows notes as a muted second line, and nothing when there are none" do
    render_row notes: "Biweekly, from Acme"

    assert_select "span.block[class~='text-base-content/70']", text: "Biweekly, from Acme"

    render_row notes: ""

    assert_select "span.block[class~='text-base-content/70']", count: 0
  end

  it "turns a negative amount red, as money does" do
    render_row amount: -30

    assert_select "span.text-error", text: "-$30.00"
  end

  it "escapes what it's given" do
    render_row description: "<b>Bonus</b>", notes: "<script>alert(1)</script>"

    assert_select "b", count: 0
    assert_select "script", count: 0
    assert_select "span", text: "<b>Bonus</b>"
  end

  describe "without anywhere to go" do
    it "is a row that isn't a link, for a record that's only read" do
      render_row href: nil

      assert_select "li a", count: 0
      assert_select "li .list-row", count: 1
      assert_select "span", text: "Paycheck"
      assert_select "span.text-right.tabular-nums", text: "$3,000.00"
    end
  end

  describe "with the year" do
    it "spells the date out with its year, for a list that goes back past the year" do
      render_row with_year: true, date: Date.new(2025, 12, 5)

      assert_select "span", text: "Dec 5, 2025"
    end

    it "leaves the year out by default" do
      render_row date: Date.new(2025, 12, 5)

      assert_select "span", text: "Dec 5"
    end
  end
end
