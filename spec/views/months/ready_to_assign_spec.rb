require "rails_helper"

# The month view's Ready to Assign card, drawn from plain figures: it takes them as locals and not a Budget::Month, so the
# styleguide can show every state without a database.
RSpec.describe "months/_ready_to_assign", type: :view do
  let(:budget) { Budget.new(currency: "CAD") }

  def figures(amount: 0, carried_over: 0, deposited: 0, assigned: 0, reallocated: 0)
    Budget::Month::ReadyToAssign.new(amount: BigDecimal(amount), carried_over: BigDecimal(carried_over),
      deposited: BigDecimal(deposited), assigned: BigDecimal(assigned), reallocated: BigDecimal(reallocated))
  end

  def render_card(ready_to_assign, current: true)
    render partial: "months/ready_to_assign", locals: {
      ready_to_assign: ready_to_assign, current: current, budget: budget,
      deposits_path: "/months/2026-09/deposits", new_deposit_path: "/deposits/new?month=2026-09&from=month"
    }
  end

  # The card's labelled figures as { "Carried over" => "$0.00", ... }.
  def labelled_figures
    css_select("dl > div").to_h { |item| [ item.at_css("dt").text.squish, item.at_css("dd").text.squish ] }
  end

  let(:to_assign) { figures(amount: 200, carried_over: 0, deposited: 3000, assigned: 2800) }
  let(:all_assigned) { figures(amount: 0, deposited: 3000, assigned: 3000) }
  let(:over_assigned) { figures(amount: -150, deposited: 100, assigned: 250) }
  let(:empty) { figures }

  describe "money left to assign" do
    it "is the big number with 'left to assign' in a warning badge, and a warning border and background, in the current month" do
      render_card to_assign, current: true

      assert_select ".stat-title [aria-describedby]", text: "Ready to Assign"
      assert_select ".stat-value", text: "$200.00"
      assert_select "section.border-warning.bg-warning\\/10"
      assert_select ".badge.badge-warning", text: "left to assign"
      assert_select ".badge-ghost", count: 0
    end

    it "is quiet in any other month: a ghost badge on the plain card, never the warning" do
      render_card to_assign, current: false

      assert_select ".stat-value", text: "$200.00"
      assert_select ".badge.badge-ghost", text: "left to assign"
      assert_select ".badge-warning", count: 0
      assert_select "section.border-base-300"
      assert_select "section.border-warning", count: 0
      assert_select "section.bg-warning\\/10", count: 0
    end

    it "keeps the text on the tinted card in the base colour: the warning is a background and a border, never text" do
      render_card to_assign, current: true

      assert_select ".text-warning", count: 0
    end
  end

  describe "everything assigned" do
    it "says so in a success badge, on a plain card, in the current month and any other" do
      [ true, false ].each do |current|
        render_card all_assigned, current: current

        assert_select ".stat-value", text: "$0.00"
        assert_select ".badge.badge-success", text: "All assigned"
        assert_select "section.border-base-300"
        assert_select "section.border-warning", count: 0
      end
    end
  end

  describe "more assigned than deposited" do
    it "is an error border and the sentence in the error colour, in the current month and any other" do
      [ true, false ].each do |current|
        render_card over_assigned, current: current

        assert_select "section.border-error"
        assert_select "section.border-warning", count: 0
        assert_select ".stat-value .text-error", text: "-$150.00"
        assert_select ".text-error", text: "More was assigned than deposited."
        assert_select ".badge", count: 0
      end
    end
  end

  describe "nothing yet" do
    it "is muted words and a New deposit button on a plain card, never the warning, in the current month and any other" do
      [ true, false ].each do |current|
        render_card empty, current: current

        assert_select ".stat-value", text: "$0.00"
        assert_select "span.text-base-content\\/70", text: "Nothing to assign yet."
        assert_select "a.btn.btn-sm[href='/deposits/new?month=2026-09&from=month']", text: "New deposit"
        assert_select "section.border-base-300"
        assert_select "section.border-warning", count: 0
        assert_select ".badge", count: 0
      end
    end

    it "is the only state with a New deposit button" do
      [ to_assign, all_assigned, over_assigned ].each do |state|
        render_card state

        assert_select "a", text: "New deposit", count: 0
      end
    end
  end

  describe "the figures" do
    it "are labelled, in the order they add up, each under its label" do
      render_card to_assign

      expect(labelled_figures.to_a).to eq([ [ "Carried over", "$0.00" ], [ "Deposited", "$3,000.00" ], [ "Assigned", "$2,800.00" ] ])
      assert_select "dl.flex.flex-wrap > div > dt.text-xs"
      assert_select "dl > div > dd.tabular-nums", count: 3
    end

    it "have no operator between them" do
      render_card to_assign

      expect(css_select("dl").text).not_to include("·")
    end

    it "include Reallocated, last, only when it isn't zero" do
      render_card figures(amount: 30, deposited: 600, assigned: 600, reallocated: 30)

      expect(labelled_figures.keys).to eq([ "Carried over", "Deposited", "Assigned", "Reallocated" ])
      expect(labelled_figures["Reallocated"]).to eq("$30.00")

      render_card to_assign

      expect(labelled_figures.keys).to eq([ "Carried over", "Deposited", "Assigned" ])
    end

    it "sign a negative one, in red" do
      render_card figures(amount: -150, carried_over: -150)

      expect(labelled_figures["Carried over"]).to eq("-$150.00")
      assert_select "dd .text-error", text: "-$150.00"
    end
  end

  describe "the way to the Deposits" do
    it "is a plain link at the foot, and the card isn't itself a link" do
      render_card to_assign

      assert_select "a[href='/months/2026-09/deposits']", text: "See Deposits", count: 1
      assert_select "a", count: 1
      assert_select "a > dl", count: 0
      assert_select "a .stat-value", count: 0
    end
  end
end
