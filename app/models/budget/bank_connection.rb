# A sign-in to a provider that a budget's Accounts are synced from instead of imported into: Splitwise first, and later a bank-sync provider
# (ADR 0016). It holds the provider's id for the login that was signed in, its name for display, the token that reads it and the date to read
# from. It belongs to its budget and never to a user, and there is one for each budget, provider and login. A Splitwise connection has exactly one
# Account, which holds that user's share of every expense.
#
# The token is encrypted at rest (Active Record encryption, with keys from the environment: see config/initializers/active_record_encryption.rb), and
# is never shown: not in a page, a log or an error message.
#
# Syncing reads from it (SyncSplitwise), holding its row lock so two syncs never run at once. `sync_cursor` is the sync marker: the provider's time of the
# latest change a sync read, as the ISO 8601 text it was sent as, which only moves forward when a sync finishes; `synced_at` is when one last did.
# Changing the date to read from (`change_read_from`) clears the marker, so the next sync reads every expense dated from the new date again.
#
# It's connected while there's a token that works. The token can stop working, which only a sync finds out and says by `needs_reconnect`, and
# Disconnect forgets it. Reconnecting the same login gives the connection a new token, so its Account and bank transactions stay (see
# ConnectSplitwise); a different login is a different connection, with an Account of its own.
class Budget::BankConnection < ApplicationRecord
  # The providers a connection can be to, which a check constraint says too, and what each is called.
  SPLITWISE = "splitwise".freeze
  PROVIDER_NAMES = { SPLITWISE => "Splitwise" }.freeze
  PROVIDERS = PROVIDER_NAMES.keys.freeze

  belongs_to :budget
  # An Account that is synced through it. It refuses to be deleted while one has it: the Account goes first, and takes the connection with it when
  # it was the last (see Budget::Account), and deleting the whole budget deletes the Accounts first.
  has_many :accounts, dependent: :restrict_with_error

  encrypts :access_token

  normalizes :login_id, :login_name, with: ->(value) { value.squish }

  validates :provider, inclusion: { in: PROVIDERS, message: "isn't supported" }
  validates :login_id, :login_name, presence: true
  validates :login_id, uniqueness: { scope: [ :budget_id, :provider ], message: "is already connected" }
  validates :read_from, presence: true
  validate :read_from_is_a_date_that_could_be_real

  # The ones that can be synced: there's a token, and nothing has found out it stopped working. What the hourly job reads.
  scope :syncable, -> { where(needs_reconnect: false).where.not(access_token: nil) }

  # Where a new connection starts reading from: the date of the budget's earliest bank transaction, so that a shared expense the person paid for, whose
  # card charge is already there, gets its share back, or the 1st of this month when there are none.
  def self.default_read_from(budget)
    budget.bank_transactions.minimum(:date) || Budget.current_month
  end

  def splitwise?
    provider == SPLITWISE
  end

  # Whether the provider's login is itself the one external account, as a Splitwise user is: their Account holds their share of every expense, so its external id is the
  # login's id, and a connection has one Account. A provider with several accounts to a login, such as a bank's, isn't.
  def login_is_the_account?
    splitwise?
  end

  # The provider's name for display, such as "Splitwise".
  def provider_name
    PROVIDER_NAMES.fetch(provider)
  end

  # There's a token, and it isn't known to have stopped working.
  def connected?
    !disconnected? && !needs_reconnect?
  end

  # The token was forgotten by Disconnect, or there never was one. Asked of what's stored and not of the token, which would need the key to read, so
  # the Account's page can still say so, and offer Reconnect, when the key is wrong or has gone.
  def disconnected?
    access_token_before_type_cast.blank?
  end

  # Where the last sync got to, as a time: the provider's own time for the latest change it read. Nothing before the first sync has finished.
  def sync_marker
    Time.iso8601(sync_cursor).utc if sync_cursor.present?
  rescue ArgumentError
    nil
  end

  # Changes the date to read from, which is true when it was changed or already was that, and false with the reasons on `errors` when it can't be. A new date means every
  # expense dated from it is to be read again, which a marker that's already past them would skip, so the marker is forgotten with it. What's already in the Account
  # stays as it is, and what's read again is matched by id, so nothing is brought in twice. Written without reading the token, as `replace_token` is, so it works for a
  # connection whose key has been lost too.
  def change_read_from(date)
    self.read_from = date
    return false unless valid?
    return true unless read_from_changed?

    update_columns(read_from: read_from, sync_cursor: nil, updated_at: Time.current)
  end

  # The token has stopped working, which only a sync finds out. Written without reading the token, which a key that's been lost couldn't, and outside the
  # sync's own database transaction, which is rolled back.
  def needs_reconnect!
    update_columns(needs_reconnect: true, updated_at: Time.current)
  end

  # Forgets the token, which stops syncing until the connection is reconnected. The Account, its bank transactions and what they were filed as are
  # untouched. With no token there's nothing to have stopped working, so that's forgotten too.
  def disconnect!
    replace_token(nil, needs_reconnect: false)
  end

  # Gives the connection a new token, for the same login, and says it works again. The login's name is refreshed, since it's what the provider
  # calls them now.
  def reconnect!(access_token:, login_name:)
    replace_token(access_token, login_name: login_name.squish, needs_reconnect: false)
  end

  private
    # Writes the token without reading the one that's there, which `update!` would to see what changed, and which can't be read once the key it was
    # encrypted under is lost. So a connection whose key has gone can still be disconnected and reconnected, which is all it can do.
    def replace_token(token, **columns)
      update_columns(access_token: token, updated_at: Time.current, **columns)
    end

    # The same limits as a CSV file's dates (Budget::CsvFormat::Reader): the day after today is allowed, since someone ahead of Eastern time may already be there.
    def read_from_is_a_date_that_could_be_real
      return if read_from.blank?

      if read_from > Date.current.tomorrow
        errors.add(:read_from, "can't be in the future")
      elsif read_from < Budget::CsvFormat::Reader::EARLIEST_DATE
        errors.add(:read_from, "can't be before #{Budget::CsvFormat::Reader::EARLIEST_DATE.year}")
      end
    end
end
