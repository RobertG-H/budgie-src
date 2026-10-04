require "rails_helper"

RSpec.describe DateRangeFilter do
  let(:today) { Date.new(2026, 10, 14) }

  def filter(from, to)
    DateRangeFilter.new(from: from, to: to, today: today)
  end

  describe "the default" do
    it "is the current month, when both ends are blank, with no error" do
      [ [ nil, nil ], [ "", "" ], [ "  ", nil ] ].each do |from, to|
        range = filter(from, to)

        expect(range).to be_valid
        expect(range.error).to be_nil
        expect([ range.from, range.to ]).to eq([ Date.new(2026, 10, 1), Date.new(2026, 10, 31) ])
        expect(range).to be_default
        expect(range.preset).to eq(:this_month)
      end
    end

    it "is the current month of the date it's given, whatever today is, and ends on the last day of a short month" do
      february = DateRangeFilter.new(from: nil, to: nil, today: Date.new(2028, 2, 10))

      expect([ february.from, february.to ]).to eq([ Date.new(2028, 2, 1), Date.new(2028, 2, 29) ])
    end

    it "is today's month by Eastern time when it's given no day" do
      travel_to Time.utc(2026, 10, 1, 0, 30)

      range = DateRangeFilter.new(from: nil, to: nil)

      expect(range.from).to eq(Date.new(2026, 9, 1))
    end
  end

  describe "a range that was chosen" do
    it "is the two dates as a date field sends them, inclusive" do
      range = filter("2026-08-15", "2026-09-02")

      expect(range).to be_valid
      expect([ range.from, range.to ]).to eq([ Date.new(2026, 8, 15), Date.new(2026, 9, 2) ])
      expect(range.range).to eq(Date.new(2026, 8, 15)..Date.new(2026, 9, 2))
      expect(range).not_to be_default
      expect(range.preset).to be_nil
    end

    it "can be a single day, with From the same as To" do
      range = filter("2026-09-02", "2026-09-02")

      expect(range).to be_valid
      expect([ range.from, range.to ]).to eq([ Date.new(2026, 9, 2), Date.new(2026, 9, 2) ])
    end

    it "hands back the dates as a date field spells them" do
      expect(filter("2026-08-15", "2026-09-02").to_params).to eq(date_from: "2026-08-15", date_to: "2026-09-02")
      expect(filter(nil, nil).to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
    end

    it "takes the dates of a year a date field takes, which has four to six digits" do
      early = filter("0001-01-01", "0001-12-31")
      late = filter("275760-01-01", "275760-09-13")

      expect(early).to be_valid
      expect(early.to_params).to eq(date_from: "0001-01-01", date_to: "0001-12-31")
      expect(late).to be_valid
      expect(late.to_params).to eq(date_from: "275760-01-01", date_to: "275760-09-13")
      expect(filter("9999-12-31", "10000-01-01")).to be_valid
    end
  end

  describe "a range that can't be used" do
    message = "Choose a From and a To date, with From first. Showing this month instead."

    define_method(:expect_this_month_instead) do |range|
      expect(range).not_to be_valid
      expect(range.error).to eq(message)
      expect([ range.from, range.to ]).to eq([ Date.new(2026, 10, 1), Date.new(2026, 10, 31) ])
      expect(range.to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
    end

    it "is an error when only one end is given" do
      expect_this_month_instead filter("2026-09-01", nil)
      expect_this_month_instead filter("", "2026-09-30")
    end

    it "is an error when an end isn't a date" do
      [ "abc", "2026-13-01", "2026-02-30", "2026-9-1", "26-09-01", "2026/09/01", "2026-09-01x", "http://example.com", "1000000-01-01", "20260901" ].each do |bad|
        expect_this_month_instead filter(bad, "2026-09-30")
        expect_this_month_instead filter("2026-09-01", bad)
      end
    end

    it "is an error when a year is outside 1 to 275760" do
      expect_this_month_instead filter("0000-12-01", "2026-09-30")
      expect_this_month_instead filter("2026-09-01", "275761-01-01")
    end

    it "is an error when From is after To, and not when they're the same day" do
      expect_this_month_instead filter("2026-09-30", "2026-09-01")
      expect(filter("2026-09-01", "2026-09-01")).to be_valid
    end

    it "is an error for something that isn't a string, such as what a hand-made query can send" do
      expect_this_month_instead filter([ "2026-09-01" ], "2026-09-30")
      expect_this_month_instead filter({ "a" => "b" }, "2026-09-30")
    end
  end

  describe "the presets" do
    it "are This month, Last month and Last 3 months, which is the current month and the two before it" do
      presets = filter(nil, nil).presets

      expect(presets.map(&:key)).to eq(%i[ this_month last_month last_3_months ])
      expect(presets.map(&:label)).to eq([ "This month", "Last month", "Last 3 months" ])
      expect(presets.map { |preset| [ preset.from, preset.to ] }).to eq([
        [ Date.new(2026, 10, 1), Date.new(2026, 10, 31) ],
        [ Date.new(2026, 9, 1), Date.new(2026, 9, 30) ],
        [ Date.new(2026, 8, 1), Date.new(2026, 10, 31) ]
      ])
    end

    it "go across the end of a year" do
      presets = DateRangeFilter.new(from: nil, to: nil, today: Date.new(2027, 1, 20)).presets

      expect(presets.map { |preset| [ preset.from, preset.to ] }).to eq([
        [ Date.new(2027, 1, 1), Date.new(2027, 1, 31) ],
        [ Date.new(2026, 12, 1), Date.new(2026, 12, 31) ],
        [ Date.new(2026, 11, 1), Date.new(2027, 1, 31) ]
      ])
    end

    it "say how to ask for themselves, as the params of a range" do
      expect(filter(nil, nil).presets.last.params).to eq(date_from: "2026-08-01", date_to: "2026-10-31")
    end

    it "are the one the range equals, and none when it equals none" do
      expect(filter("2026-09-01", "2026-09-30").preset).to eq(:last_month)
      expect(filter("2026-08-01", "2026-10-31").preset).to eq(:last_3_months)
      expect(filter("2026-10-01", "2026-10-31").preset).to eq(:this_month)
      expect(filter("2026-09-02", "2026-09-30").preset).to be_nil
      expect(filter("2026-08-01", "2026-10-30").preset).to be_nil
    end
  end
end
