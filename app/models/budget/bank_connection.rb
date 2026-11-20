# A sign-in to a provider that a budget's Accounts are synced from instead of imported into: Splitwise first, and later a bank-sync provider
# (ADR 0016). It holds the provider's id for the login that was signed in, its name for display and the token that reads it. It belongs to its
# budget and never to a user, and there is one for each budget, provider and login. A Splitwise connection has exactly one Account, which holds that
# user's share of every expense. The date to read from is each Account's own (Budget::Account#read_from).
#
# The token is encrypted at rest (Active Record encryption, with keys from the environment: see config/initializers/active_record_encryption.rb), and
# is never shown: not in a page, a log or an error message.
#
# Syncing reads from it (`sync`, which is SyncSplitwise or SyncPlaid), holding its row lock so two syncs never run at once. `sync_cursor` is where the last sync got
# to, as text the provider's sync owns and nothing else reads (for Splitwise, a time: SyncSplitwise.sync_marker; for Plaid, Plaid's own cursor); `synced_at` is when
# one last finished. Changing an
# Account's date to read from forgets it (`forget_sync_cursor!`), so the next sync reads everything dated from the new date again.
#
# It's connected while there's a token that works. The token can stop working, which only a sync finds out and says by `needs_reconnect`, and
# Disconnect forgets it. Reconnecting the same login gives the connection a new token, so its Account and bank transactions stay (see
# ConnectSplitwise); a different login is a different connection, with an Account of its own.
#
# A bank connected through Plaid (ADR 0018) is one Plaid Item: `login_id` is the Item's id, `login_name` the bank's name ("TD Canada Trust"), and `institution_id`
# Plaid's id for the bank ("ins_42"), which the check before an exchange compares (ConnectPlaid). It has an Account for each of the bank's accounts that the person
# chose to connect, each with Plaid's id, name and mask for it, and one cursor for all of them.
class Budget::BankConnection < ApplicationRecord
  # The providers a connection can be to, which a check constraint says too, and what each is called.
  SPLITWISE = "splitwise".freeze
  PLAID = "plaid".freeze
  PROVIDER_NAMES = { SPLITWISE => "Splitwise", PLAID => "Plaid" }.freeze
  PROVIDERS = PROVIDER_NAMES.keys.freeze
  # What Plaid says to `/item/remove` when there's nothing left to remove: the Item is gone already (removed at my.plaid.com, say), or its access token isn't one it
  # knows. Either way Budgie's access has ended, which is what was asked for.
  ITEM_ALREADY_REMOVED = %w[ ITEM_NOT_FOUND INVALID_ACCESS_TOKEN ].freeze

  belongs_to :budget
  # An Account that is synced through it. It refuses to be deleted while one has it: the Account goes first, and takes the connection with it when
  # it was the last (see Budget::Account), and deleting the whole budget deletes the Accounts first.
  has_many :accounts, dependent: :restrict_with_error

  encrypts :access_token

  normalizes :login_id, :login_name, with: ->(value) { value.squish }

  validates :provider, inclusion: { in: PROVIDERS, message: "isn't supported" }
  validates :login_id, :login_name, presence: true
  validates :login_id, uniqueness: { scope: [ :budget_id, :provider ], message: "is already connected" }
  validates :institution_id, presence: true, if: :plaid?

  # The ones that can be synced: there's a token, and nothing has found out it stopped working. What the hourly job reads.
  scope :syncable, -> { where(needs_reconnect: false).where.not(access_token: nil) }
  scope :splitwise, -> { where(provider: SPLITWISE) }
  scope :plaid, -> { where(provider: PLAID) }

  def splitwise?
    provider == SPLITWISE
  end

  def plaid?
    provider == PLAID
  end

  # What it reads, in words: Splitwise's expenses (its own word for them, which a person knows them by) or a bank's bank transactions.
  def reads
    splitwise? ? "expenses" : "bank transactions"
  end

  # What a person knows it by: the bank's name for a bank ("TD Canada Trust"), and the provider's for Splitwise. Never the word for Plaid's own idea of it.
  def name
    plaid? ? login_name : provider_name
  end

  # The bank's name as far as its first word goes ("TD" for "TD Canada Trust", "Tartan" for "Tartan-Dominion Bank of Canada"), which a button that has to be short
  # names it by ("Sync TD now"), and the whole of a name that has no word.
  def self.short_name(name)
    name.to_s[/\A[[:alnum:]]+/] || name.to_s
  end

  def short_name
    self.class.short_name(name)
  end

  # Brings what's new in, through its provider's sync, and says what it did (SyncSplitwise::Result or SyncPlaid::Result, which answer the same questions).
  def sync
    (splitwise? ? SyncSplitwise : SyncPlaid).call(self)
  end

  # Whether its provider is set up on this host, which syncing needs: without the provider's keys, and the ones the token is encrypted under, nothing can be read.
  def provider_configured?
    splitwise? ? Splitwise.configured? : PlaidApi.configured?
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

  # Forgets where the last sync got to, so the next one starts again from the date to read from: what an Account's new date to read from needs
  # (Budget::Account#change_read_from). Written without reading the token, as `replace_token` is, so it works for a connection whose key has been lost too.
  def forget_sync_cursor!
    update_columns(sync_cursor: nil, updated_at: Time.current)
  end

  # The token has stopped working, which only a sync finds out. Written without reading the token, which a key that's been lost couldn't, and outside the
  # sync's own database transaction, which is rolled back.
  def needs_reconnect!
    update_columns(needs_reconnect: true, updated_at: Time.current)
  end

  # The token works again, which a bank's Reconnect (Plaid's update mode) finds out once Plaid answers with it, and the token stays as it was. Written without reading
  # the token, as `needs_reconnect!` is.
  def clear_needs_reconnect!
    update_columns(needs_reconnect: false, updated_at: Time.current)
  end

  # Forgets the token, which stops syncing until the connection is reconnected. The Account, its bank transactions and what they were filed as are
  # untouched. With no token there's nothing to have stopped working, so that's forgotten too.
  def disconnect!
    replace_token(nil, needs_reconnect: false)
  end

  # Ends Budgie's access to a bank for good: asks Plaid to remove the Item, which also ends its billing, and only then forgets the token. The Accounts, their bank
  # transactions and what they were filed as stay. Plaid is called first and nothing is written until it has answered, and never inside a database transaction that a
  # failed write could roll back after Plaid has been told, so the worst a failure afterwards leaves is a connection whose Item is already gone, which the next sync
  # finds out (SyncPlaid) and disconnects. It raises PlaidApi::Error, and leaves the token, when Plaid can't be reached or refuses; a key that's been lost, which the
  # token can't be read without, raises ActiveRecord::Encryption::Errors::Decryption, since then Plaid can't be told. A connection that's already disconnected has no
  # Item left to remove.
  def disconnect_from_plaid!
    remove_at_plaid
    disconnect!
  end

  # Asks Plaid to remove the Item, as far as that's needed: the same as `disconnect_from_plaid!` without forgetting the token, for deleting a connection's last Account,
  # which deletes the connection instead.
  def remove_at_plaid
    return if disconnected?
    raise PlaidApi::Error, "Plaid isn't set up here." unless PlaidApi.configured?

    PlaidApi.client.remove_item(access_token)
  rescue PlaidApi::Error => error
    raise unless ITEM_ALREADY_REMOVED.include?(error.error_code)
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
end
