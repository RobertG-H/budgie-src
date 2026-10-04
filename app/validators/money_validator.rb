# An amount of money in a decimal(15, 2) column: a number under LIMIT in size, with at most 2 decimal places.
# It may be negative unless `positive: true`, which asks for more than 0.
#
#   validates :starting_balance, money: true
#   validates :amount, money: { positive: true }
class MoneyValidator < ActiveModel::EachValidator
  # decimal(15, 2) holds 13 digits before the decimal point.
  LIMIT = 10**13

  def initialize(options)
    super
    @numericality = ActiveModel::Validations::NumericalityValidator.new(
      attributes: attributes, greater_than: options[:positive] ? 0 : -LIMIT, less_than: LIMIT
    )
  end

  def validate(record)
    @numericality.validate(record)
    super
  end

  # The column rounds to 2 places, so this checks what was entered before it's rounded. Only a number can have
  # too many decimal places, so an attribute that's already been refused is left alone.
  def validate_each(record, attribute, _value)
    return if record.errors.include?(attribute)

    entered = BigDecimal(record.public_send(:"#{attribute}_before_type_cast").to_s.strip, exception: false)
    record.errors.add(attribute, "can't have more than 2 decimal places") if entered && entered.round(2) != entered
  end
end
