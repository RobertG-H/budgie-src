require "rails_helper"

RSpec.describe "components/_month_links", type: :view do
  # Unsaved: the links only need the months either side, which take no queries.
  let(:budget) { Budget.new(currency: "CAD") }

  before { travel_to Time.utc(2026, 9, 15, 16) }

  def render_links(date, path: ->(month) { "/pages/#{month.to_param}" })
    render partial: "components/month_links", locals: { month: Budget::Month.new(budget, date), path: path }
  end

  it "links to the months either side, named for them" do
    render_links Date.new(2026, 9, 1)

    assert_select "nav[aria-label=Months]"
    assert_select "a[rel=prev][href='/pages/2026-08']", text: "August 2026"
    assert_select "a[rel=next][href='/pages/2026-10']", text: "October 2026"
  end

  it "crosses the end of a year" do
    render_links Date.new(2026, 12, 1)

    assert_select "a[rel=next][href='/pages/2027-01']", text: "January 2027"

    render_links Date.new(2027, 1, 1)

    assert_select "a[rel=prev][href='/pages/2026-12']", text: "December 2026"
  end

  it "doesn't offer This month while it's the month being viewed" do
    render_links Date.new(2026, 9, 1)

    assert_select "a", text: "This month", count: 0
  end

  it "offers This month, going to the current month, when viewing another" do
    render_links Date.new(2027, 3, 1)

    assert_select "a[href='/pages/2026-09']", text: "This month"
  end

  it "builds every link with the path it's given, so they stay on the page they're on" do
    render_links Date.new(2027, 3, 1), path: ->(month) { "/months/#{month.to_param}/deposits" }

    assert_select "a[href='/months/2027-02/deposits']", text: "February 2027"
    assert_select "a[href='/months/2027-04/deposits']", text: "April 2027"
    assert_select "a[href='/months/2026-09/deposits']", text: "This month"
  end
end
