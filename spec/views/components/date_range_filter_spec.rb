require "rails_helper"

RSpec.describe "components/_date_range_filter", type: :view do
  let(:today) { Date.new(2026, 10, 14) }

  def render_filter(from, to, path: ->(dates) { "/records?#{dates.to_query}" })
    filter = DateRangeFilter.new(from: from, to: to, today: today)
    render inline: <<~ERB, locals: { filter: filter, path: path }
      <%= form_with url: "/records", method: :get, scope: :filter do |form| %>
        <%= render "components/date_range_filter", form: form, filter: filter, path: path %>
      <% end %>
    ERB
  end

  it "has From and To as labelled date fields named for a filter, starting on the range" do
    render_filter "2026-09-02", "2026-09-30"

    assert_select "label[for=filter_date_from]", text: "From"
    assert_select "label[for=filter_date_to]", text: "To"
    assert_select "input[type=date][name='filter[date_from]'][value='2026-09-02']"
    assert_select "input[type=date][name='filter[date_to]'][value='2026-09-30']"
  end

  it "starts on the current month when the range is blank, or can't be used" do
    render_filter nil, nil
    assert_select "input[name='filter[date_from]'][value='2026-10-01']"

    render_filter "2026-09-30", "2026-09-01"
    assert_select "input[name='filter[date_from]'][value='2026-10-01']"
    assert_select "input[name='filter[date_to]'][value='2026-10-31']"
  end

  it "spells a year of any length the way a date field does" do
    render_filter "0001-01-01", "275760-09-13"

    assert_select "input[name='filter[date_from]'][value='0001-01-01']"
    assert_select "input[name='filter[date_to]'][value='275760-09-13']"
  end

  it "has an Apply button that sends no name of its own" do
    render_filter nil, nil

    assert_select "input[type=submit][value=Apply]:not([name])"
  end

  it "has the three presets as links to the path they're given with their two dates" do
    render_filter nil, nil

    assert_select "a[href='/records?date_from=2026-10-01&date_to=2026-10-31']", text: "This month"
    assert_select "a[href='/records?date_from=2026-09-01&date_to=2026-09-30']", text: "Last month"
    assert_select "a[href='/records?date_from=2026-08-01&date_to=2026-10-31']", text: "Last 3 months"
  end

  it "marks the preset the range equals, filled and for assistive technology, and none when it equals none" do
    render_filter "2026-09-01", "2026-09-30"

    assert_select "a[aria-current=true]", count: 1
    assert_select "a.btn-neutral[aria-current=true]", text: "Last month"
    assert_select "a[aria-current]", count: 1

    render_filter "2026-09-02", "2026-09-30"

    assert_select "a[aria-current]", count: 0
  end
end
