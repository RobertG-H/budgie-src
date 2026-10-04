# Starts the new month of every budget that's behind: copies each envelope's Assigned amount from the month before into
# the month that has just begun. It runs every hour, so a month begins within an hour of midnight Eastern, and a run that
# was missed is made up by the next one. See Budget#start_new_months.
class StartNewMonthsJob < ApplicationJob
  queue_as :default

  def perform
    Budget.with_months_to_start.find_each(&:start_new_months)
  end
end
