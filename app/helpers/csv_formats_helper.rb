module CsvFormatsHelper
  # How a CSV format reads a file, in a sentence a person can check against their file, such as "Date in column 1 as
  # MM/DD/YYYY. Description in column 2. Amount in column 3, with money out as a negative amount."
  def csv_format_summary(csv_format)
    columns = csv_format.description_columns
    description = "Description in #{"column".pluralize(columns.size)} #{columns.to_sentence}."
    amount = case csv_format.amount_style
    when "signed" then "Amount in column #{csv_format.amount_column}, with money out as a negative amount."
    when "in_and_out" then "Money in in column #{csv_format.money_in_column}, and money out in column #{csv_format.money_out_column}."
    when "direction"
      "Amount in column #{csv_format.amount_column}, with money in when column #{csv_format.direction_column} says #{csv_format.money_in_value}."
    end

    [ "Date in column #{csv_format.date_column} as #{csv_format.date_format}.", description, amount, ("The sign is inverted." if csv_format.invert_sign) ].compact.join(" ")
  end

  # A date as a person reads it, spelled out so that a month can't be mistaken for a day: "Sep 3, 2026".
  def spelled_date(date)
    date.strftime("%b %-d, %Y")
  end
end
