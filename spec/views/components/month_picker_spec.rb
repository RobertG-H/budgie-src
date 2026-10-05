require "rails_helper"

# The picker's dialog, as the server draws it for the viewed year. The Stimulus controller redraws the grid for another year
# and does the keyboard, which there are no system specs for: that's checked in the Visual review.
RSpec.describe "components/_month_picker", type: :view do
  let(:budget) { Budget.new(currency: "CAD") }

  before { travel_to Time.utc(2026, 9, 15, 16) }

  def render_picker(date)
    render partial: "components/month_picker", locals: { month: Budget::Month.new(budget, date), path: ->(month) { "/months/#{month.to_param}" } }
  end

  it "is a native dialog labelled by its title, with a Close button in its action row" do
    render_picker Date.new(2026, 10, 1)

    assert_select "dialog.modal[aria-labelledby]" do |dialog|
      title = css_select("##{dialog.first['aria-labelledby']}").first

      expect(title.text.squish).to eq("Choose a month")
    end
    assert_select "dialog .modal-action form[method=dialog] button.btn", text: "Close"
  end

  describe "the year stepper" do
    it "is a button either side of a numeric input with the viewed year, between 1 and 275760" do
      render_picker Date.new(2026, 10, 1)

      assert_select "input[type=number][min='1'][max='275760'][inputmode=numeric][value='2026']", count: 1
      assert_select "button[data-month-picker-target=previousYear]", count: 1
      assert_select "button[data-month-picker-target=nextYear]", count: 1
      assert_select "button[disabled]", count: 0
      assert_select "label[for]", text: "Year"
    end

    it "is named for what each button does" do
      render_picker Date.new(2026, 10, 1)

      assert_select "button[data-month-picker-target=previousYear][aria-label='Previous year']"
      assert_select "button[data-month-picker-target=nextYear][aria-label='Next year']"
    end
  end

  describe "the grid of months" do
    it "is 12 links in three columns, short names, each to its month of the viewed year" do
      render_picker Date.new(2026, 10, 1)

      assert_select "[role=group].grid.grid-cols-3 a", count: 12
      names = css_select("a[data-month-picker-target=month]").map { |link| link.text.squish }
      expect(names).to eq(%w[ Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec ])
      hrefs = css_select("a[data-month-picker-target=month]").map { |link| link["href"] }
      expect(hrefs).to eq((1..12).map { |month| format("/months/2026-%02d", month) })
    end

    it "names each month in full for assistive technology" do
      render_picker Date.new(2026, 10, 1)

      assert_select "a[href='/months/2026-01'][aria-label='January 2026']", text: "Jan"
      assert_select "a[href='/months/2026-12'][aria-label='December 2026']", text: "Dec"
    end

    it "marks the viewed month as the current page, filled" do
      render_picker Date.new(2026, 10, 1)

      assert_select "a[aria-current=page]", count: 1
      assert_select "a.btn-primary[href='/months/2026-10'][aria-current=page]", text: "Oct"
      assert_select "a.btn-primary", count: 1
    end

    it "marks this calendar month by an outline and in its name, when it isn't the viewed one" do
      render_picker Date.new(2026, 10, 1)

      assert_select "a.btn-outline[href='/months/2026-09'][aria-label='September 2026, this month']", text: "Sep"
      assert_select "a.btn-outline", count: 1
      assert_select "a[aria-label*='this month']", count: 1
    end

    it "marks one month when the viewed month is this one: filled, and still named as this month" do
      render_picker Date.new(2026, 9, 1)

      assert_select "a.btn-primary[aria-current=page][aria-label='September 2026, this month']", text: "Sep"
      assert_select "a.btn-outline", count: 0
    end

    it "marks neither in a year with neither in it" do
      render_picker Date.new(2031, 2, 1)

      assert_select "a[href='/months/2031-02'].btn-primary[aria-current=page]"
      assert_select "a.btn-outline", count: 0
      assert_select "a[aria-label*='this month']", count: 0
      assert_select "a[href='/months/2031-12'][aria-label='December 2031']"
    end

    it "is one tab stop: the viewed month's, with the others out of the tab order" do
      render_picker Date.new(2026, 10, 1)

      expect(css_select("a[data-month-picker-target=month]").map { |link| link["tabindex"] }).to eq(%w[ -1 -1 -1 -1 -1 -1 -1 -1 -1 0 -1 -1 ])
    end

    it "spells a year of any length the way the address does" do
      render_picker Date.new(1, 1, 1)
      assert_select "a[href='/months/0001-01'][aria-label='January 0001']"

      render_picker Date.new(275760, 9, 1)
      assert_select "a[href='/months/275760-09'][aria-label='September 275760'][aria-current=page]"
      assert_select "input[value='275760']"
    end
  end

  describe "This month" do
    it "is a button-looking link to the current month under the grid, so the word is on screen" do
      render_picker Date.new(2031, 2, 1)

      assert_select "a.btn[href='/months/2026-09'][data-month-picker-target=thisMonth]", text: "This month"
    end

    it "is in the tab order after the grid, and before Close: the stepper, the grid, This month, Close" do
      render_picker Date.new(2031, 2, 1)

      stops = css_select("a, button, input").map { |element| element["data-month-picker-target"] || element.text.squish }
      expect(stops).to eq(%w[ previousYear year nextYear ] + [ "month" ] * 12 + %w[ thisMonth Close ])
    end
  end
end
