# What a filtered page was given as its `filter` param, read the same way for every page that has one (Budget::RecordList, Budget::BankTransactionList): the
# values by name, whatever it was sent as. ActionController::Parameters and a Hash are read, and anything else, such as the string a hand-made query can send, is
# no values at all. What each page makes of them is up to it, which keeps only what it understands.
module Budget::FilterValues
  def self.read(filter)
    values = filter.respond_to?(:to_unsafe_h) ? filter.to_unsafe_h : (filter.is_a?(Hash) ? filter : {})
    values.with_indifferent_access
  end
end
