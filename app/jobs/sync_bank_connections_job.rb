# Syncs every connection that can be synced, which is what keeps each Splitwise Account up to date between the times someone presses Sync now. It runs every hour
# in production, which is testing as well. See SyncSplitwise.
#
# A connection that needs reconnecting, or was disconnected, is skipped until it's reconnected (Budget::BankConnection.syncable). Splitwise no longer accepting a sign-in, or
# limiting how often it can be asked, is for the person to hear about on the Account's page and not a failure of the run: the first is marked on the connection, and the
# second is tried again next time. Anything else that goes wrong doesn't hold up the connections after it: it's logged with the connection's id (its sync is rolled back whole,
# so the next run tries it again), and the first is raised once the rest are done, so the run shows as failed rather than passing unnoticed, as StartNewMonthsJob does.
class SyncBankConnectionsJob < ApplicationJob
  queue_as :default

  def perform
    # A token can't be read without its keys, and a host without them never made a connection.
    return unless Splitwise.configured?

    failures = []

    Budget::BankConnection.syncable.find_each do |connection|
      # Splitwise is the only provider there is. A second one adds its own service here, chosen by `connection.provider`.
      result = SyncSplitwise.call(connection)
      next unless result.error

      Rails.logger.error "Couldn't sync connection #{connection.id}: #{result.error.class}: #{result.error.message}"
      failures << result.error
    rescue => error
      Rails.logger.error "Couldn't sync connection #{connection.id}: #{error.class}: #{error.message}"
      failures << error
    end

    raise failures.first if failures.any?
  end
end
