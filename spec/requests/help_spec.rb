require "rails_helper"

# Tooltips and plain-words help: the words that need it are explained in one sentence each (`help:` in config/locales/en.yml), as a tooltip
# for a keyboard or a mouse and, since a phone can't hover, in words on the page too.
RSpec.describe "Help", type: :request do
  let(:budget) { create(:budget) }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  before { sign_in_as budget.user }

  def help(key)
    I18n.t("help.#{key}")
  end

  # The tooltip around the term or button called `name`.
  def tooltip_on(name)
    css_select(".tooltip").find { |tip| tip.at_css("[aria-describedby]")&.text&.squish == name } or raise "no tooltip on #{name}"
  end

  # The term is described by the real element that holds the sentence: found by the id, which is on the page once.
  def expect_tooltip(name, key)
    tip = tooltip_on(name)
    described = tip.at_css("[aria-describedby]")
    content = tip.at_css(".tooltip-content[role=tooltip]")

    expect(content.text.squish).to eq(help(key))
    expect(described["aria-describedby"]).to eq(content["id"])
    expect(css_select("[id='#{content["id"]}']").size).to eq(1)
  end

  # The closed <details> that says the same in words.
  def figures
    css_select("main details").find { |details| details.at_css("summary").text.squish == "What do these figures mean?" } or raise "no figures"
  end

  def explained(details)
    details.css("dl > div").to_h { |item| [ item.at_css("dt").text.squish, item.at_css("dd").text.squish ] }
  end

  describe "the month view" do
    before { get month_path("2026-09") }

    it "explains the Ready to Assign card's title and the Carried over, Assigned and Reallocated headers, as a tooltip" do
      expect_tooltip "Ready to Assign", :ready_to_assign
      expect(tooltip_on("Ready to Assign").ancestors("section").first["id"]).to eq("ready-to-assign")

      %w[ carried_over assigned reallocated ].each do |key|
        name = key.humanize
        expect_tooltip name, key
        expect(tooltip_on(name).ancestors("th")).not_to be_empty
      end
    end

    it "puts a header's tooltip below it, where the top of a table would cut it off" do
      %w[ Carried\ over Assigned Reallocated ].each { |name| expect(tooltip_on(name)["class"].split).to include("tooltip-bottom") }
    end

    it "makes a plain term a tab stop, and never explains in a title or a data-tip, which a keyboard, a touch and a screen reader don't get" do
      expect(tooltip_on("Assigned").at_css("[aria-describedby]")["tabindex"]).to eq("0")
      assert_select "[data-tip]", count: 0
      assert_select ".tooltip [title]", count: 0
    end

    it "says the same in words, in a closed <details> under the table: Ready to Assign, Assigned, Carried over, Reallocated and Available" do
      expect(figures["open"]).to be_nil
      expect(explained(figures)).to eq(
        "Ready to Assign" => help(:ready_to_assign), "Assigned" => help(:assigned), "Carried over" => help(:carried_over),
        "Reallocated" => help(:reallocated), "Available" => help(:available)
      )
      expect(css_select("main table, main details > summary").map(&:name)).to eq(%w[ table summary ])
    end

    it "doesn't give the <details> terms a tooltip of their own, which would put each id on the page twice" do
      ids = css_select("[role=tooltip]").map { |tip| tip["id"] }
      expect(ids).to eq(ids.uniq)
    end
  end

  it "puts the <details> above the Archived envelopes, which is where a person looks for what's put away" do
    other = create(:budget_envelope, budget: budget, name: "Gym")
    other.archive!

    get month_path("2026-09")

    expect(css_select("main details > summary").map { |summary| summary.text.squish }).to eq([ "What do these figures mean?", "Archived envelopes" ])
  end

  it "has the <details> on a month view that has no envelopes too, since the card's title is explained there" do
    budget.envelopes.destroy_all

    get month_path("2026-09")

    expect_tooltip "Ready to Assign", :ready_to_assign
    expect(explained(figures).keys).to include("Ready to Assign")
  end

  describe "an envelope's page" do
    before { get month_envelope_path("2026-09", groceries) }

    it "explains the stat cards Carried over, Assigned, Reallocated and Available as a tooltip" do
      { "Carried over" => :carried_over, "Assigned" => :assigned, "Reallocated" => :reallocated, "Available" => :available }.each do |name, key|
        expect_tooltip name, key
        expect(tooltip_on(name).ancestors(".stat-title")).not_to be_empty
      end
    end

    it "explains the Reallocate and Archive buttons, wrapping the tooltip around the button and not adding a tab stop" do
      { "Reallocate" => :reallocate, "Archive" => :archive }.each do |name, key|
        expect_tooltip name, key
        tip = tooltip_on(name)
        expect(tip.at_css("[aria-describedby]")["tabindex"]).to be_nil
        expect(tip.css("[tabindex]")).to be_empty
      end
      assert_select "a.btn[href^='#{new_reallocation_path}'][aria-describedby]", text: "Reallocate"
      assert_select "button.btn[aria-describedby]", text: "Archive"
    end

    it "keeps the Archive button a button in its own form, which the tooltip only wraps" do
      assert_select ".tooltip form[action='#{envelope_archive_path(groceries)}'] button", text: "Archive"
    end

    it "says the same in words, with Reallocate and Archive as well" do
      expect(explained(figures)).to eq(
        "Ready to Assign" => help(:ready_to_assign), "Assigned" => help(:assigned), "Carried over" => help(:carried_over),
        "Reallocated" => help(:reallocated), "Available" => help(:available), "Reallocate" => help(:reallocate), "Archive" => help(:archive)
      )
      expect(figures["open"]).to be_nil
    end

    it "has every tooltip's id once" do
      ids = css_select("[role=tooltip]").map { |tip| tip["id"] }
      expect(ids.size).to be >= 6
      expect(ids).to eq(ids.uniq)
    end
  end

  describe "an archived envelope's page" do
    before do
      groceries.archive!
      get month_envelope_path("2026-09", groceries)
    end

    it "has no Reallocate to explain, and explains Unarchive's page the same way" do
      expect(css_select(".tooltip").map { |tip| tip.at_css("[aria-describedby]").text.squish }).not_to include("Reallocate")
      expect_tooltip "Available", :available
    end
  end

  describe "the Reallocate form" do
    before { get new_reallocation_path(month: "2026-09", from: "envelope", envelope: groceries.id) }

    it "says under its title what it's for, and that Assigned is how to give an envelope more of Ready to Assign" do
      assert_select "main h1 + p", text: help(:reallocate_form)
      expect(help(:reallocate_form)).to include("use Assigned on the month view")
    end

    it "has no tooltips: the paragraph says it" do
      assert_select ".tooltip", count: 0
    end
  end

  it "uses every sentence in config/locales/en.yml on a page, so none can drift unnoticed" do
    text = []
    get month_path("2026-09")
    text << Nokogiri::HTML(response.body).at("main").text.squish
    get month_envelope_path("2026-09", groceries)
    text << Nokogiri::HTML(response.body).at("main").text.squish
    get new_reallocation_path(month: "2026-09", from: "envelope", envelope: groceries.id)
    text << Nokogiri::HTML(response.body).at("main").text.squish
    on_the_pages = text.join(" ")

    keys = I18n.t("help").keys
    expect(keys).to include(:ready_to_assign, :assigned, :carried_over, :reallocated, :reallocate, :archive, :available, :reallocate_form)
    keys.each { |key| expect(on_the_pages).to include(help(key)), "help.#{key} isn't on a page" }
  end

  it "doesn't add a query to the month view: the same number with one envelope as with several" do
    few = count_queries { get month_path("2026-09") }
    create(:budget_envelope, budget: budget, name: "Rent")
    create(:budget_envelope, budget: budget, name: "Fuel")
    many = count_queries { get month_path("2026-09") }

    expect(many).to eq(few)
  end
end
