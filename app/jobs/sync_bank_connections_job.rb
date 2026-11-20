# Syncs every connection that can be synced, which is what keeps each synced Account up to date between the times someone presses Sync now: a Splitwise Account's
# shares and a bank's bank transactions. It runs every hour in production, which is testing as well. Each connection goes to its provider's sync
# (Budget::BankConnection#sync: SyncSplitwise or SyncPlaid), and a provider that isn't set up on this host is skipped, since its tokens can't be read there.
#
# A connection that needs reconnecting, or was disconnected, is skipped until it's reconnected (Budget::BankConnection.syncable). The provider no longer accepting a
# connection, or limiting how often it can be asked, is for the person to hear about on the Account's page and not a failure of the run: the first is marked on the
# connection, and the second is tried again next time. Anything else that goes wrong doesn't hold up the connections after it: it's logged with the connection's id (its
# sync is rolled back whole, so the next run tries it again), and the first is raised once the rest are done, so the run shows as failed rather than passing unnoticed,
# as StartNewMonthsJob does.
class SyncBankConnectionsJob < ApplicationJob
  queue_as :default

  def perform
    failures = []

    Budget::BankConnection.syncable.find_each do |connection|
      next unless connection.provider_configured?

      error = connection.sync.error
      failures << failed(connection, error) if error
    rescue => error
      failures << failed(connection, error)
    end

    raise failures.first if failures.any?
  end

  private
    # Logged with the connection's id, and kept to be raised once the rest are done.
    def failed(connection, error)
      Rails.logger.error "Couldn't sync connection #{connection.id}: #{error.class}: #{error.message}"
      error
    end
end
