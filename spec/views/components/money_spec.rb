require "rails_helper"

RSpec.describe "components/_money", type: :view do
  let(:budget) { Budget.new(currency: "CAD") }

  def render_money(**locals)
    render partial: "components/money", locals: { budget: budget }.merge(locals)
  end

  it "shows an amount in the budget's currency, in normal text" do
    render_money amount: 1234.5

    assert_select "span", text: "$1,234.50"
    assert_select ".text-error", count: 0
  end

  it "keeps a negative amount's sign and turns it red" do
    render_money amount: -30

    assert_select "span.text-error", text: "-$30.00"
  end

  it "says Overspent in words only when asked to" do
    render_money amount: -30
    assert_select ".badge", count: 0

    render_money amount: -30, overspent: true
    assert_select ".badge", text: "Overspent"
  end
end
