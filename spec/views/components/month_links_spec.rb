require "rails_helper"

RSpec.describe "components/_month_links", type: :view do
  # Unsaved: the links only need the months either side, which take no queries.
  let(:budget) { Budget.new(currency: "CAD") }

  before { travel_to Time.utc(2026, 9, 15, 16) }

  def render_links(date, path: ->(month) { "/pages/#{month.to_param}" }, picker: nil)
    locals = { month: Budget::Month.new(budget, date), path: path }
    locals[:picker] = picker unless picker.nil?
    render partial: "components/month_links", locals: locals
  end

  # The words of a link that a person sees, not the ones that name it for assistive technology.
  def words(selector)
    css_select(selector).map { |link| link.text.squish }
  end

  it "links to the months either side, named for them" do
    render_links Date.new(2026, 9, 1)

    assert_select "nav[aria-label=Months]"
    assert_select "a[rel=prev][href='/pages/2026-08']", text: /August 2026/
    assert_select "a[rel=next][href='/pages/2026-10']", text: /October 2026/
  end

  it "crosses the end of a year" do
    render_links Date.new(2026, 12, 1)

    assert_select "a[rel=next][href='/pages/2027-01']", text: /January 2027/

    render_links Date.new(2027, 1, 1)

    assert_select "a[rel=prev][href='/pages/2026-12']", text: /December 2026/
  end

  it "doesn't offer This month while it's the month being viewed" do
    render_links Date.new(2026, 9, 1)

    assert_select "a", text: "This month", count: 0
  end

  it "offers This month, going to the current month, as a ghost button beside the control when viewing another" do
    render_links Date.new(2027, 3, 1)

    assert_select "a.btn.btn-ghost.btn-sm[href='/pages/2026-09']", text: "This month"
  end

  it "builds every link with the path it's given, so they stay on the page they're on" do
    render_links Date.new(2027, 3, 1), path: ->(month) { "/months/#{month.to_param}/deposits" }

    assert_select "a[href='/months/2027-02/deposits']", text: /February 2027/
    assert_select "a[href='/months/2027-04/deposits']", text: /April 2027/
    assert_select "a[href='/months/2026-09/deposits']", text: "This month"
  end

  describe "the control" do
    it "is one left-aligned row, with Previous, the month's name and Next joined as three small buttons" do
      render_links Date.new(2026, 9, 1)

      assert_select "nav[aria-label=Months].flex.flex-wrap.items-center.gap-2"
      assert_select "nav .join .join-item.btn.btn-sm", count: 3
      assert_select "nav .join > a.join-item[rel=prev]"
      assert_select "nav .join > a.join-item[rel=next]"
      expect(css_select("nav .join > *").map { |item| item["rel"] }).to eq([ "prev", nil, "next" ])
    end

    it "names the month between Previous and Next, as plain text when there's no picker" do
      render_links Date.new(2026, 9, 1)

      expect(words("nav .join > :nth-child(2)")).to eq([ "September 2026" ])
      assert_select "nav .join > :nth-child(2) button", count: 0
      assert_select "dialog", count: 0
      assert_select "[data-controller]", count: 0
    end

    it "shows only a chevron on a phone, and the neighbouring month's name from sm up" do
      render_links Date.new(2026, 9, 1)

      assert_select "a[rel=prev] span[aria-hidden=true]", text: "‹"
      assert_select "a[rel=next] span[aria-hidden=true]", text: "›"
      assert_select "a[rel=prev] span.hidden.sm\\:inline", text: "August 2026"
      assert_select "a[rel=next] span.hidden.sm\\:inline", text: "October 2026"
    end

    it "always names Previous and Next with their month, whatever is on screen" do
      render_links Date.new(2026, 9, 1)

      assert_select "a[rel=prev][aria-label='Previous month, August 2026']"
      assert_select "a[rel=next][aria-label='Next month, October 2026']"
    end

    it "stops Previous in January of year 1, where there's no month before: it's shown, disabled, and not a link" do
      render_links Date.new(1, 1, 1)

      assert_select "a[rel=prev]", count: 0
      assert_select "nav .join > button.join-item[disabled][aria-disabled=true]", count: 1
      assert_select "nav .join > button[disabled] span[aria-hidden=true]", text: "‹"
      assert_select "a[rel=next][href='/pages/0001-02']", text: /February 0001/
    end

    it "has Previous in February of year 1, and Next without a bound" do
      render_links Date.new(1, 2, 1)

      assert_select "a[rel=prev][href='/pages/0001-01']", text: /January 0001/

      render_links Date.new(275760, 9, 1)

      assert_select "a[rel=next][href='/pages/275760-10']", text: /October 275760/
    end
  end

  describe "with the picker" do
    it "has the month's name as plain text for a page without JavaScript, and a button hidden until the controller reveals it" do
      render_links Date.new(2026, 9, 1), picker: true

      assert_select "nav .join > :nth-child(2)[data-month-picker-target=name]", text: "September 2026"
      assert_select "nav .join > button.join-item[hidden][data-month-picker-target=trigger][aria-haspopup=dialog]", count: 1
      assert_select "button[data-month-picker-target=trigger][aria-label='September 2026, choose a month']", text: /September 2026/
      assert_select "button[data-month-picker-target=trigger] svg[aria-hidden=true]"
    end

    it "keeps working Previous, Next and This month without JavaScript" do
      render_links Date.new(2027, 3, 1), picker: true

      assert_select "a[rel=prev][href='/pages/2027-02']"
      assert_select "a[rel=next][href='/pages/2027-04']"
      assert_select "nav a[href='/pages/2026-09']", text: "This month"
    end

    it "is opened by the modal controller and gets the viewed and the current month, and where the months go" do
      render_links Date.new(2027, 3, 1), picker: true

      assert_select "[data-controller='modal month-picker']" do |wrapper|
        expect(wrapper.first["data-month-picker-year-value"]).to eq("2027")
        expect(wrapper.first["data-month-picker-month-value"]).to eq("3")
        expect(wrapper.first["data-month-picker-current-year-value"]).to eq("2026")
        expect(wrapper.first["data-month-picker-current-month-value"]).to eq("9")
        expect(wrapper.first["data-month-picker-href-value"]).to eq("/pages/{month}")
      end
      assert_select "button[data-action='modal#open month-picker#open']"
      assert_select "dialog.modal[data-modal-target=dialog][data-month-picker-target=dialog]", count: 1
    end

    it "is nothing without it: the picker is for the month view only" do
      render_links Date.new(2026, 9, 1), picker: false

      assert_select "dialog", count: 0
      assert_select "[data-controller]", count: 0
      assert_select "button", count: 0
    end
  end
end
