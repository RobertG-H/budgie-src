module QueryCounter
  # The number of SQL queries the block runs. Schema lookups and transaction statements aren't counted.
  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[ SCHEMA TRANSACTION ].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end

RSpec.configure do |config|
  config.include QueryCounter
end
