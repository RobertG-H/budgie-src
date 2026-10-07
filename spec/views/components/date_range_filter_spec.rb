require "rails_helper"

RSpec.describe "components/_date_range_filter", type: :view do
  let(:today) { Date.new(2026, 10, 14) }

  def render_filter(from, to, path: ->(dates) { "/records?#{dates.to_query}" }, optional: false, **options)
    filter = DateRangeFilter.new(from: from, to: to, today: today, optional: optional)
    render inline: <<~ERB, locals: { filter: filter, path: path, options: options }
      <%= form_with url: "/records", method: :get, scope: :filter do |form| %>
        <%= render "components/date_range_filter", form: form, filter: filter, path: path, **options %>
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

  describe "for a state that doesn't use the range" do
    it "shows the fields disabled, so they send nothing, with the hint that says why, and the fields described by it" do
      render_filter nil, nil, disabled: true, hint: "Unfiled bank transactions are listed whatever their date."

      assert_select "input[type=date][name='filter[date_from]'][disabled]:not([required])"
      assert_select "input[type=date][name='filter[date_to]'][disabled]"
      assert_select "p#filter_date_range_hint", text: "Unfiled bank transactions are listed whatever their date."
      assert_select "input[name='filter[date_from]'][aria-describedby=filter_date_range_hint]"
      assert_select "input[name='filter[date_to]'][aria-describedby=filter_date_range_hint]"
    end

    it "leaves the presets out, which have nothing to set, and keeps Apply, which sends the other filters" do
      render_filter nil, nil, disabled: true, hint: "Why."

      assert_select "a", count: 0
      assert_select "input[type=submit][value=Apply]"
    end

    it "has no hint, and enabled fields, otherwise" do
      render_filter nil, nil

      assert_select "p#filter_date_range_hint", count: 0
      assert_select "input[type=date][disabled]", count: 0
      assert_select "input[type=date][required]", count: 2
      assert_select "input[type=date][aria-describedby]", count: 0
    end
  end

  describe "an optional range" do
    it "starts with empty fields that aren't required, and Any date marked first among the presets, which sets no dates" do
      render_filter nil, nil, optional: true

      assert_select "input[type=date][name='filter[date_from]']:not([value]):not([required])"
      assert_select "input[type=date][name='filter[date_to]']:not([value]):not([required])"
      expect(css_select("a.btn").map { |link| link.text.squish }).to eq([ "Any date", "This month", "Last month", "Last 3 months" ])
      assert_select "a.btn-neutral[aria-current=true]", text: "Any date"
      assert_select "a", text: "Any date" do |links|
        expect(links.first["href"]).to eq("/records?")
      end
    end

    it "starts on the dates it's given, with those required fields' values and no preset marked when it equals none" do
      render_filter "2026-09-02", "2026-09-30", optional: true

      assert_select "input[type=date][name='filter[date_from]'][value='2026-09-02']:not([required])"
      assert_select "a[aria-current=true]", count: 0
    end

    it "leaves Any date out of a range that isn't optional" do
      render_filter nil, nil

      assert_select "a", text: "Any date", count: 0
      assert_select "input[type=date][required]", count: 2
    end
  end
end
