# What Plaid Link gave the browser when a person finished it, kept in the session until they've chosen what each account they shared becomes (ADR 0018):
# the public token, the bank (Plaid's id for it and its name) and each account's id, name, mask and kind, with the time Link finished and the budget it was for,
# as SplitwiseSignIn keeps its state. The public token is exchanged only when the choice is submitted (ConnectPlaid), and only within 30 minutes of Link finishing,
# which is when Plaid stops accepting it.
#
# Choose accounts keeps one too, for a connection that's already there (`update?`): Link's update mode gives back the whole selection of accounts and nothing to
# exchange, so it has the connection and the Account it was started from in place of a public token, and the bank's name is the connection's.
#
# None of it is trusted for anything but skipping an exchange: the duplicate check reads the bank and each account's name and mask from here, and what's stored
# comes from Plaid's own `/accounts/get` once the token is exchanged. The session is an encrypted cookie, so the person can't change it, but the browser could
# have sent anything to begin with, so it's kept short: a few accounts, and short strings.
class PendingPlaidLink
  SESSION_KEY = "pending_plaid_link".freeze

  # How long the public token lasts at Plaid, and so how long the person has to choose.
  VALID_FOR = 30.minutes

  # The most accounts one connect can bring, which keeps what's kept inside the session's cookie.
  MAX_ACCOUNTS = 15

  # How much of a string is kept, which a real one never comes near.
  MAX_LENGTH = 100

  # One account the person shared in Link, as Link said it.
  SharedAccount = Data.define(:id, :name, :mask, :subtype)

  attr_reader :public_token, :institution_id, :institution_name, :accounts, :linked_at, :budget_id, :connection_id, :account_id

  def initialize(public_token:, institution_id:, institution_name:, accounts:, linked_at:, budget_id:, connection_id: nil, account_id: nil)
    @public_token = public_token
    @institution_id = institution_id
    @institution_name = institution_name
    @accounts = accounts
    @linked_at = linked_at
    @budget_id = budget_id
    @connection_id = connection_id
    @account_id = account_id
  end

  # What Link's `onSuccess` sent, for `budget`, as Link finished now. Nil when it isn't something Link would send: no public token, no bank or no account.
  # More accounts than one connect can bring is nil too, and the page says so (see `too_many_accounts?`).
  def self.from_params(params, budget:)
    return unless params.respond_to?(:fetch)

    accounts = shared_accounts(params)
    link = new(public_token: clean(params[:public_token]), institution_id: clean(params[:institution_id]), institution_name: clean(params[:institution_name]),
      accounts: accounts, linked_at: Time.current, budget_id: budget.id)
    link if link.public_token && link.institution_id && link.institution_name && accounts.any?
  end

  # What Link's `onSuccess` sent in update mode with account selection, which is every account now shared, for the connection `account` is synced from, as Link
  # finished now. Nil when it names no account. More accounts than can be kept is said by `too_many_accounts?`, as for a new connection.
  def self.for_selection(params, account:)
    accounts = params.respond_to?(:fetch) ? shared_accounts(params) : []
    connection = account.bank_connection
    link = new(public_token: nil, institution_id: connection.institution_id, institution_name: connection.name, accounts: accounts, linked_at: Time.current,
      budget_id: account.budget_id, connection_id: connection.id, account_id: account.id)
    link if accounts.any?
  end

  # What was kept in the session, or nil when nothing was, or it isn't what this class keeps.
  def self.from_session(value)
    return unless value.is_a?(Hash) && value["accounts"].is_a?(Array)
    return unless value["public_token"].is_a?(String) || value["connection_id"].is_a?(Integer)

    new(public_token: value["public_token"], institution_id: value["institution_id"], institution_name: value["institution_name"],
      accounts: value["accounts"].map { SharedAccount.new(id: it["id"], name: it["name"], mask: it["mask"], subtype: it["subtype"]) },
      linked_at: Time.zone.at(value["linked_at"].to_i), budget_id: value["budget_id"], connection_id: value["connection_id"], account_id: value["account_id"])
  end

  # A value of plain strings and numbers, for the session.
  def to_session
    { "public_token" => public_token, "institution_id" => institution_id, "institution_name" => institution_name,
      "accounts" => accounts.map { it.to_h.stringify_keys }, "linked_at" => linked_at.to_i, "budget_id" => budget_id,
      "connection_id" => connection_id, "account_id" => account_id }.compact
  end

  # Whether it's Choose accounts on a connection that's already there, and not a new connection.
  def update?
    connection_id.present?
  end

  def too_many_accounts?
    accounts.size > MAX_ACCOUNTS
  end

  # Whether the 30 minutes since Link finished are up.
  def expired?
    linked_at <= VALID_FOR.ago
  end

  def for?(budget)
    budget_id == budget.id
  end

  # Never the token.
  def inspect
    "#<#{self.class.name} institution_id=#{institution_id.inspect} accounts=#{accounts.size}>"
  end
  alias_method :to_s, :inspect

  # Each account Link sent, by its id, with a name and the rest as they're kept.
  def self.shared_accounts(params)
    Array(params[:accounts].presence&.then { it.respond_to?(:values) ? it.values : it }).filter_map do |account|
      next unless account.respond_to?(:fetch) && (id = clean(account[:id]))

      SharedAccount.new(id: id, name: clean(account[:name]) || "Account", mask: clean(account[:mask]), subtype: clean(account[:subtype]))
    end.uniq(&:id)
  end
  private_class_method :shared_accounts

  # A string as it's kept: squished, at most MAX_LENGTH characters, and nil when it's blank or isn't a string. The duplicate check reads a stored Account's Plaid
  # name and mask the same way, so the two compare equal (ConnectPlaid).
  def self.clean(value)
    value.to_s.squish.first(MAX_LENGTH).presence if value.is_a?(String)
  end
end
