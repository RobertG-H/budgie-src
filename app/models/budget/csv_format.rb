# How one bank's CSV download is laid out: which columns hold the date, the description and the amount, and which way the
# sign runs. A person builds it from a sample of the file and saves it under a name, so later files from that bank read
# the same way. There are no built-in formats. The rest, from reading a file to refusing one, is in
# Budget::CsvFormat::Reader.
#
# Columns are numbered from 1, as the builder's grid numbers them. `column_count` is the sample's, and every column a
# format names has to be within it.
class Budget::CsvFormat < ApplicationRecord
  DATE_FORMATS = [ "YYYY-MM-DD", "MM/DD/YYYY", "DD/MM/YYYY", "YYYYMMDD" ].freeze

  # How a file says how much money moved, and which way:
  # - signed: one column, negative for money out
  # - in_and_out: one column for money in and another for money out
  # - direction: one column of unsigned amounts, and another that says which way each went
  AMOUNT_STYLES = %w[ signed in_and_out direction ].freeze

  # The columns and values each style uses. The rest are left unset, so that the database's checks, which tie them to the
  # style, hold for whatever the form sent.
  AMOUNT_ATTRIBUTES = { "signed" => %i[ amount_column ], "in_and_out" => %i[ money_in_column money_out_column ],
                        "direction" => %i[ amount_column direction_column money_in_value ] }.freeze

  # More than any bank's file has, so that a number that's silly is refused instead of overflowing a column.
  MAX_COLUMNS = 100
  MAX_ROWS_TO_SKIP = 1000

  belongs_to :budget
  # A CSV format that an Import used can't be deleted, but it can still be edited, which never touches what was imported.
  has_many :imports, dependent: :restrict_with_error
  # The Accounts it's the default of. Deleting a format that's only a default works and clears it from each of them, which is why this is
  # declared after the check above that refuses when an Import used it: it only runs when the delete isn't refused.
  has_many :default_for_accounts, class_name: "Budget::Account", foreign_key: :default_csv_format_id, inverse_of: :default_csv_format,
    dependent: :nullify

  normalizes :name, with: ->(name) { name.squish }
  normalizes :money_in_value, with: ->(value) { value.strip }

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }

  before_validation :clear_unused_amount_attributes

  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false }
  validates :rows_to_skip, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_ROWS_TO_SKIP }
  validates :column_count, presence: { message: "must be chosen, so the columns can be read from it" }
  validates :column_count, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_COLUMNS }, allow_nil: true
  validates :date_format, inclusion: { in: DATE_FORMATS, message: "must be chosen" }
  validates :amount_style, inclusion: { in: AMOUNT_STYLES, message: "must be chosen" }
  validates :invert_sign, inclusion: { in: [ true, false ] }
  validate :date_and_description_columns
  validate :amount_columns

  # Reads a file with this format: its rows, each a date, a description and a signed amount, or the first row it refuses.
  # See Reader.
  def read(file)
    Reader.new(self).read(file)
  end

  # A blank field means no rows are skipped.
  def rows_to_skip=(value)
    super(value.presence || 0)
  end

  # The numbers a person types, such as "2" or "2, 3", are the columns. Anything else in what's typed is 0, which isn't a
  # column, so it's refused instead of being read as one.
  def description_columns=(value)
    super(value.is_a?(String) ? value.split(/[\s,]+/).compact_blank.map { |column| Integer(column, 10, exception: false) || 0 } : value)
  end

  private
    def clear_unused_amount_attributes
      used = AMOUNT_ATTRIBUTES[amount_style] or return

      (AMOUNT_ATTRIBUTES.values.flatten.uniq - used).each { |attribute| self[attribute] = nil }
    end

    def date_and_description_columns
      validate_column(:date_column)

      if description_columns.blank?
        errors.add(:description_columns, :blank)
      else
        errors.add(:description_columns, "can't repeat a column") if description_columns.uniq.size != description_columns.size
        errors.add(:description_columns, column_message) unless description_columns.all? { |column| within_columns?(column) }
      end
    end

    def amount_columns
      case amount_style
      when "signed"
        validate_column(:amount_column)
      when "in_and_out"
        validate_column(:money_in_column)
        validate_column(:money_out_column)
        errors.add(:money_out_column, "can't be the same column as money in") if money_in_column && money_in_column == money_out_column
      when "direction"
        validate_column(:amount_column)
        validate_column(:direction_column)
        errors.add(:direction_column, "can't be the same column as the amount") if amount_column && amount_column == direction_column
        errors.add(:money_in_value, :blank) if money_in_value.blank?
      end
    end

    def validate_column(attribute)
      column = self[attribute]

      if column.nil?
        errors.add(attribute, :blank)
      elsif !within_columns?(column)
        errors.add(attribute, column_message)
      end
    end

    # Without a known number of columns there's nothing to be within, and that has its own error.
    def within_columns?(column)
      !column_count.to_i.positive? || column.between?(1, column_count)
    end

    def column_message
      "must be one of the sample's columns, 1 to #{column_count}"
    end
end
