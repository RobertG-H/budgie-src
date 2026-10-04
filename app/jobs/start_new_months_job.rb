# Starts the new month of every budget that's behind: copies each envelope's Assigned amount from the month before into
# the month that has just begun. It runs every hour, so a month begins within an hour of midnight Eastern, and a run that
# was missed is made up by the next one. See Budget#start_new_months.
#
# A budget that can't be started doesn't hold up the ones after it. Its month is rolled back whole, so the next run
# tries it again. Each failure is logged with the budget's id, and the first is raised once the rest are done, so the run
# shows as failed rather than passing unnoticed.
class StartNewMonthsJob < ApplicationJob
  queue_as :default

  def perform
    failures = []

    Budget.with_months_to_start.find_each do |budget|
      budget.start_new_months
    rescue => error
      Rails.logger.error "Couldn't start the new months of budget #{budget.id}: #{error.class}: #{error.message}"
      failures << error
    end

    raise failures.first if failures.any?
  end
end
