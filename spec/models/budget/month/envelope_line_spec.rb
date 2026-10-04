require "rails_helper"

RSpec.describe Budget::Month::EnvelopeLine do
  # A line from its figures, with Available worked out from them as Budget::Month does. The envelope isn't read here.
  def line(carried_over: 0, assigned: 0, spent: 0, refunded: 0, reallocated: 0)
    figures = { carried_over: carried_over, assigned: assigned, spent: spent, refunded: refunded, reallocated: reallocated }
      .transform_values { |amount| BigDecimal(amount.to_s) }
    described_class.new(envelope: nil, **figures, available: figures.values_at(:carried_over, :assigned, :refunded, :reallocated).sum - figures[:spent])
  end

  describe "#had_to_spend" do
    it "is Carried over, Assigned, Refunded and Reallocated added up" do
      expect(line(carried_over: 10, assigned: 100, refunded: 5, reallocated: 20, spent: 40).had_to_spend).to eq(135)
    end

    it "leaves out a negative Carried over, which an Overspent envelope carries in" do
      expect(line(carried_over: -30, assigned: 100, spent: 20).had_to_spend).to eq(100)
    end

    it "leaves out a negative Reallocated, which is more moved out than in" do
      expect(line(assigned: 100, reallocated: -30).had_to_spend).to eq(100)
    end
  end

  describe "#available_level" do
    it "is plenty when most of what the envelope had is left" do
      expect(line(assigned: 100, spent: 20).available_level).to eq(:plenty)
    end

    it "is plenty at exactly 25%, and a little just under it" do
      expect(line(assigned: 100, spent: 75).available_level).to eq(:plenty)
      expect(line(assigned: 100, spent: BigDecimal("75.01")).available_level).to eq(:little)
    end

    it "is a little when everything has been spent" do
      expect(line(assigned: 100, spent: 100).available_level).to eq(:little)
    end

    it "is a little for a tiny amount left" do
      expect(line(assigned: 5, spent: BigDecimal("4.50")).available_level).to eq(:little)
    end

    it "is overspent when Available is below zero" do
      expect(line(assigned: 100, spent: 130).available_level).to eq(:overspent)
    end

    it "is overspent even when the envelope had nothing to spend, as a negative Starting balance alone leaves it" do
      expect(line(carried_over: -80).available_level).to eq(:overspent)
    end

    it "is none when there was nothing to spend and nothing spent" do
      expect(line.available_level).to eq(:none)
    end

    it "is overspent for an envelope that only had money moved out of it, which had nothing to spend" do
      expect(line(reallocated: -5).available_level).to eq(:overspent)
    end

    it "is plenty for money carried over and not touched" do
      expect(line(carried_over: 50).available_level).to eq(:plenty)
    end
  end

  describe "#available_percent" do
    it "is the share of what the envelope had that's Available, in whole percent" do
      expect(line(assigned: 400, spent: 100).available_percent).to eq(75)
      expect(line(assigned: 3, spent: 1).available_percent).to eq(66)
    end

    it "is the tiny share it is, with no minimum" do
      expect(line(assigned: 5, spent: BigDecimal("4.50")).available_percent).to eq(10)
    end

    it "rounds down, so the bar is under 25 exactly when the level is a little" do
      almost = line(assigned: 1000, spent: BigDecimal("753"))

      expect(almost.available_level).to eq(:little)
      expect(almost.available_percent).to eq(24)
      expect(line(assigned: 1000, spent: 750).available_percent).to eq(25)
    end

    it "is 0 when everything is spent" do
      expect(line(assigned: 100, spent: 100).available_percent).to eq(0)
    end

    it "is 100 when nothing is spent" do
      expect(line(assigned: 100).available_percent).to eq(100)
    end

    it "is 100 when Overspent, a full bar, with or without anything to spend" do
      expect(line(assigned: 100, spent: 130).available_percent).to eq(100)
      expect(line(carried_over: -80).available_percent).to eq(100)
    end

    it "is nothing when there's no bar" do
      expect(line.available_percent).to be_nil
    end

    it "is never over 100 with a Refund, a negative Carried over or a negative Reallocated" do
      [
        line(assigned: 100, refunded: 40),
        line(carried_over: -30, assigned: 100, refunded: 10),
        line(assigned: 100, reallocated: -30),
        line(carried_over: -10, assigned: 100, reallocated: 50, refunded: 5),
        line(assigned: 100, spent: 10, refunded: 60, reallocated: -20)
      ].each do |figures|
        expect(figures.available_percent).to be_between(0, 100)
      end
    end

    it "counts a Refund in what the envelope had, so spending it back leaves it a little" do
      line = line(assigned: 100, refunded: 20, spent: 100)

      expect(line.available_percent).to eq(16)
      expect(line.available_level).to eq(:little)
    end
  end
end
