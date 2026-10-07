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

  describe "with a checkbox for choosing the row" do
    let(:checkbox) { '<input type="checkbox" name="ids[]" value="7" class="checkbox" aria-label="Select Paycheck">'.html_safe }

    it "is in a cell of its own outside the row's link, which still opens the record, with room for it at the start of the row" do
      render_row checkbox: checkbox

      assert_select "li.relative" do
        assert_select "label.absolute.w-12 input[type=checkbox][name='ids[]']"
        assert_select "a.list-row.pl-12[href='/deposits/7/edit']"
        assert_select "a input", count: 0
      end
    end

    it "is also for a row that isn't a link, which keeps its place" do
      render_row href: nil, checkbox: checkbox

      assert_select "li.relative label.absolute input[type=checkbox]"
      assert_select "li div.list-row.pl-12"
      assert_select "li a", count: 0
    end

    it "makes no difference to a row without one" do
      render_row

      assert_select "li.relative", count: 0
      assert_select "label", count: 0
      assert_select "a.list-row.pl-12", count: 0
    end
  end
end
