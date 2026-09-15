# Sent emails accumulate in ActionMailer::Base.deliveries, so each example starts with none.
RSpec.configure do |config|
  config.before do
    ActionMailer::Base.deliveries.clear
  end
end
