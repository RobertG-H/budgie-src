require "rails_helper"

# How a CSV format reads a date in the order its day, month and year are in, and how the builder chooses that order from a
# sample. The reader's own spec reads dates in files; this one is the order on its own.
RSpec.describe Budget::CsvFormat::DateOrder do
  before { travel_to Time.utc(2026, 10, 15, 16) }

  def read(order, text)
    described_class.new(order).read(text)
  end

  describe "#read" do
    it "reads eight digits by the order's widths" do
      expect(read("year_month_day", "20261007")).to eq(Date.new(2026, 10, 7))
      expect(read("month_day_year", "10072026")).to eq(Date.new(2026, 10, 7))
      expect(read("day_month_year", "07102026")).to eq(Date.new(2026, 10, 7))
    end

    it "reads a month as a word whichever of the other orders it's in, and the year first only for year, month, day" do
      expect(read("month_day_year", "7 Oct 2026")).to eq(Date.new(2026, 10, 7))
      expect(read("day_month_year", "Oct. 7, 2026")).to eq(Date.new(2026, 10, 7))
      expect(read("year_month_day", "2026 October 7")).to eq(Date.new(2026, 10, 7))
      expect(read("day_month_year", "2026 October 7")).to be_nil
    end

    it "takes a two-digit year only after the day" do
      expect(read("day_month_year", "07/10/26")).to eq(Date.new(2026, 10, 7))
      expect(read("year_month_day", "26/10/07")).to be_nil
    end

    it "refuses a date that isn't on the calendar, and anything that isn't a date" do
      expect(read("year_month_day", "2026-02-29")).to be_nil
      expect(read("year_month_day", "2028-02-29")).to eq(Date.new(2028, 2, 29))
      [ "", "yesterday", "2026-10", "2026-10-07-01", "2026_10_07", "Oct 7", "7 Oct", "Monday" ].each do |text|
        expect(read("year_month_day", text)).to be_nil, text
      end
    end
  end

  describe ".detect" do
    it "is the only order that reads every date" do
      expect(described_class.detect([ "2026-10-07", "2026-10-08" ])).to eq("year_month_day")
      expect(described_class.detect([ "10/07/2026", "10/13/2026" ])).to eq("month_day_year")
      expect(described_class.detect([ "07/10/2026", "13/10/2026" ])).to eq("day_month_year")
    end

    it "is nothing when the dates read more than one way, or none" do
      expect(described_class.detect([ "04/09/2026", "05/09/2026" ])).to be_nil
      expect(described_class.detect([ "13/13/2026" ])).to be_nil
      expect(described_class.detect([ "", "  " ])).to be_nil
    end

    it "rules out an order that reads a date the reader wouldn't take, after tomorrow" do
      expect(described_class.detect([ "12/10/2026" ])).to eq("day_month_year") # December 10 is after tomorrow, so it is October 12.
    end

    it "chooses the order that looks like the file when two read a month as a word the same" do
      expect(described_class.detect([ "Oct 7, 2026" ])).to eq("month_day_year")
      expect(described_class.detect([ "Wed, Oct 7, 2026" ])).to eq("month_day_year")
      expect(described_class.detect([ "7 Oct 2026" ])).to eq("day_month_year")
    end
  end
end
