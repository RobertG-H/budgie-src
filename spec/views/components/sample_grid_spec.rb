require "rails_helper"

RSpec.describe "components/_sample_grid", type: :view do
  def sample_of(text, rows_to_skip: 0)
    Budget::CsvFormat::Sample.new(text, rows_to_skip: rows_to_skip)
  end

  def render_grid(sample)
    render partial: "components/sample_grid", locals: { sample: sample }
  end

  it "numbers the columns, and gives each row its line" do
    render_grid sample_of("Date,Description,Amount\n2026-09-01,Paycheck,10.00\n")

    assert_select "thead th[scope=col]", text: "Line"
    assert_select "thead th[scope=col]", count: 4
    assert_select "thead th[scope=col]:nth-child(4)", text: "3"
    assert_select "tbody tr:nth-child(1) th[scope=row]", text: "1"
    assert_select "tbody tr:nth-child(2) th[scope=row]", text: "2"
    assert_select "tbody tr:nth-child(2) td:nth-child(3)", text: "Paycheck"
  end

  it "says which rows are skipped in a word, and mutes them" do
    render_grid sample_of("Account: Chequing\nDate,Description,Amount\n2026-09-01,Paycheck,10.00\n", rows_to_skip: 2)

    assert_select "tbody tr:nth-child(1) .badge", text: "Skipped"
    assert_select "tbody tr:nth-child(2) .badge", text: "Skipped"
    assert_select "tbody tr:nth-child(3) .badge", count: 0
    assert_select "tbody tr:nth-child(1)[class~='text-base-content/70']"
    assert_select "tbody tr:nth-child(3)[class~='text-base-content/70']", count: 0
  end

  it "gives every row the width of the widest, so a short one is padded" do
    render_grid sample_of("a,b,c\nd\n")

    assert_select "tbody tr:nth-child(2) td", count: 3
  end

  it "scrolls by itself when it's wider than the page, and says what it is for assistive technology" do
    render_grid sample_of("a,b,c\n")

    assert_select "div.overflow-x-auto table caption.sr-only", text: "The first rows of the sample file, with its columns numbered"
  end

  it "shows only the first rows, however many the sample has" do
    render_grid sample_of("a,b\n" * 30)

    assert_select "tbody tr", count: 10
  end

  it "escapes the cells, which are whatever the file had in them" do
    render_grid sample_of("<script>alert(1)</script>,b\n")

    assert_select "script", count: 0
    expect(rendered).to include("&lt;script&gt;")
  end
end
