# Connects a bank once a person has been through Plaid Link and chosen what each account they shared becomes: a new Account, linked onto an Account that's there
# (one that takes CSV Imports, or one whose bank was disconnected, `Budget::Account.linkable`), or left out (ADR 0018). The checks run in this order, and everything before the exchange spends no Item, which on Plaid's Trial is one of ten for good:
#
# 1. the deadline: Plaid's public token lasts 30 minutes from when Link finished;
# 2. the choices: at least one account becomes an Account or is linked onto one, every name and date is one an Account could have, and no Account is linked onto
#    twice (a mistake is said on the page);
# 3. the duplicate check: the same bank as one of the budget's live Plaid connections, with an account whose name and mask are one of that connection's Accounts',
#    is that login again, which is refused and pointed at Reconnect or Choose accounts; the same bank with none of them is a second login, and is allowed. An
#    overlap with a disconnected connection's Account is no reason to refuse: that row starts on linking onto it (`choices`);
# 4. the exchange, which makes the Item;
# 5. `/accounts/get`: every account chosen must be one Plaid has (anything else was crafted), an account in another currency is left out, and what's stored about
#    each account comes from here, never from what the browser sent;
# 6. the connection and its Accounts, in one database transaction holding the budget's row lock: new ones made, and linked ones given the connection, with a
#    disconnected connection that's left with no Accounts deleted.
#
# Once there's an Item, anything that stops it being connected removes it (`/item/remove`), so nothing is kept at Plaid either. A refusal's words never carry a
# token or Plaid's whole answer. It knows nothing of sessions or redirects: PlaidChoicesController does.
class ConnectPlaid
  # What came of it: `connected?` with the connection, its new Accounts and a notice; `invalid?` with the choices and their errors (and `error` for the page as a
  # whole), for the page to say; or `refused?` with an alert, when nothing was kept and there's nothing on the page to fix.
  Result = Data.define(:status, :connection, :accounts, :notice, :alert, :choices, :error) do
    def connected? = status == :connected
    def invalid? = status == :invalid
    def refused? = status == :refused
  end

  # An Account a shared account can be linked onto, as the choice page offers it: its id and name, and the date to start reading from, which is its latest bank
  # transaction's, that day included, so a day the bank posted more on after the CSV file was downloaded isn't lost (that day's may come in twice, unfiled), or
  # where a new Account would start when it has none.
  LinkTarget = Data.define(:id, :name, :read_from)

  # What one shared account becomes, as the choice page has it: `becomes` is "new", "leave" or "link:<the Account's id>", one of `targets`. A new Account's `name`
  # and `read_from` go with it, and a linked one's `link_read_from`, a field of its own since both are on the page. Its errors are an Account's own (its name taken,
  # a date that couldn't be real) on the same fields. `index` is its place in what Link sent, which the page's fields are numbered by. `left_out_reason` says why it
  # can only be left out, which is an account in another currency when that's known before anything is saved (Choose accounts).
  class Choice
    include ActiveModel::Model
    include ActiveModel::Attributes

    NEW = "new".freeze
    LEAVE = "leave".freeze
    BECOMES = [ NEW, LEAVE ].freeze
    LINK_PREFIX = "link:".freeze

    attribute :becomes, :string, default: NEW
    attribute :name, :string
    attribute :read_from, :date
    attribute :link_read_from, :date
    attr_accessor :shared_account, :index, :left_out_reason
    attr_writer :targets

    def self.human_attribute_name(attribute, options = {})
      { "name" => "Account name", "read_from" => "Date to read from", "link_read_from" => "Date to read from", "becomes" => "Becomes" }.fetch(attribute.to_s) { super }
    end

    # What `becomes` is for linking onto the Account with `id`.
    def self.link_value(id)
      "#{LINK_PREFIX}#{id}"
    end

    def targets
      @targets || []
    end

    def new_account?
      becomes == NEW
    end

    def linking?
      becomes.to_s.start_with?(LINK_PREFIX)
    end

    # The Account it's linked onto, as one of `targets`, or nil when it isn't linked or names one that isn't offered.
    def link_target
      return unless linking?

      id = becomes.delete_prefix(LINK_PREFIX)
      targets.find { it.id.to_s == id }
    end

    # Whether it becomes an Account, new or linked onto, which is what connecting needs at least one of.
    def connecting?
      new_account? || linking?
    end

    def left_out?
      left_out_reason.present?
    end
  end

  # An Account chosen to link onto that can't be by the time it's saved, such as one another request connected since the page was checked.
  class Unlinkable < StandardError; end

  DEADLINE = "Nothing was connected, since the accounts weren't chosen within 30 minutes. Connect again to choose them.".freeze
  NONE_CHOSEN = "Choose at least one account to connect.".freeze
  CHOSEN_TWICE = "is already chosen for another account on this page".freeze

  # The choices for `link`'s accounts, or only the ones in `only`: what was sent for each, by its place in the list (`params`, the form's `accounts`), or, for the
  # page as it starts, a new Account each, named for the bank and the account and reading from where the budget's bank transactions start, except one that's
  # a disconnected connection's Account at the same bank (`overlaps`), which starts linked onto it. Each offers the budget's `link_targets`, and a linked one
  # reads from its target's date unless a date was sent. `params` is what the controller permitted.
  def self.choices(budget, link, params = nil, only: nil)
    read_from = Budget::Account.default_read_from(budget)
    targets = link_targets(budget, read_from)
    overlaps = overlaps(budget, link)
    sent_by_index = params.respond_to?(:to_h) ? params.to_h.with_indifferent_access : {}

    link.accounts.each_with_index.filter_map do |shared, index|
      next if only && !only.include?(shared)

      sent = sent_by_index[index.to_s]
      sent = sent.respond_to?(:slice) ? sent.slice(:becomes, :name, :read_from, :link_read_from).to_h.symbolize_keys : {}
      started = overlaps.key?(shared.id) ? Choice.link_value(overlaps[shared.id]) : Choice::NEW
      Choice.new(shared_account: shared, index: index, becomes: started, name: default_name(link, shared), read_from: read_from, targets: targets, **sent).tap do |choice|
        choice.link_read_from = choice.link_target&.read_from unless sent.key?(:link_read_from)
      end
    end
  end

  # The Accounts a shared account can be linked onto (`Budget::Account.linkable`), by name, each with the date it starts reading from: its latest bank
  # transaction's, or `default` when it has none. Two queries, however many there are.
  def self.link_targets(budget, default)
    accounts = budget.accounts.linkable.alphabetical.pluck(:id, :name)
    latest = Budget::BankTransaction.where(account_id: accounts.map(&:first)).group(:account_id).maximum(:date)
    accounts.map { |id, name| LinkTarget.new(id: id, name: name, read_from: latest.fetch(id, default)) }
  end

  # The shared accounts that are an Account of one of the budget's disconnected connections at the same bank, by their Plaid name and mask, as the duplicate check
  # compares them: `{ shared account's id => that Account's id }`, each Account for the first shared account it matches only.
  def self.overlaps(budget, link)
    accounts = budget.accounts.joins(:bank_connection).alphabetical
      .where(bank_connection: { provider: Budget::BankConnection::PLAID, institution_id: link.institution_id, access_token: nil })
    remaining = accounts.to_a

    link.accounts.each_with_object({}) do |shared, overlapping|
      match = remaining.find { [ PendingPlaidLink.clean(it.external_name), PendingPlaidLink.clean(it.external_mask) ] == [ shared.name, shared.mask ] }
      next unless match

      overlapping[shared.id] = match.id
      remaining.delete(match)
    end
  end

  # Checks each choice as the Account it would make would be (`build` makes it, unsaved, with its connection), so a name that's taken or a date that couldn't be real
  # is said on the page, and two new Accounts can't be given the same name either. True when no choice has an error.
  #
  # A linked one must be onto one of the Accounts offered, not one another row has already chosen, and its date is checked as an Account's would be.
  def self.check_choices(choices, &build)
    linked = []
    choices.each do |choice|
      choice.errors.clear
      if choice.linking? && choice.link_target
        target = choice.link_target
        choice.errors.add(:becomes, CHOSEN_TWICE) if linked.include?(target.id)
        linked << target.id
        problem = Budget::Account.read_from_problem(choice.link_read_from)
        choice.errors.add(:link_read_from, problem) if problem
      elsif !Choice::BECOMES.include?(choice.becomes)
        choice.errors.add(:becomes, "isn't one of the choices")
      end
    end

    names = []
    choices.select(&:new_account?).each do |choice|
      account = build.call(choice)
      account.validate
      account.errors.each { |error| choice.errors.add(error.attribute, error.message) if error.attribute.in?([ :name, :read_from ]) }

      key = account.name.to_s.downcase
      choice.errors.add(:name, "is the same as another account's on this page") if key.present? && names.include?(key) && choice.errors[:name].none?
      names << key
    end

    choices.none? { it.errors.any? }
  end

  # The bank and the account ("TD Canada Trust Visa Infinite"), unless the account's name already starts with the bank's first word ("TD Every Day Chequing"),
  # which is its letters up to a hyphen or a space, so "Tartan U.S. Dollar" at Tartan-Dominion Bank of Canada isn't named for the bank twice, and "Tartanic" isn't
  # taken for "Tartan".
  def self.default_name(link, shared)
    first_word = link.institution_name.to_s[/\A[[:alnum:]]+/]
    named_for_the_bank = first_word && shared.name.match?(/\A#{Regexp.escape(first_word)}(?![[:alnum:]])/i)
    named_for_the_bank ? shared.name : "#{link.institution_name} #{shared.name}".squish
  end

  # The Account `choice` makes in `connection`, for `plaid_account` as `/accounts/get` says it, which is where its id, name and mask come from, with Filing rules on.
  def self.create_account(connection, choice, plaid_account)
    connection.budget.accounts.create!(name: choice.name, read_from: choice.read_from, bank_connection: connection, external_account_id: plaid_account.id,
      external_name: plaid_account.name || choice.shared_account.name, external_mask: plaid_account.mask, files_with_rules: true)
  end

  # The Account `choice` links onto, given `connection` and what `/accounts/get` says of `plaid_account`, with its date. It keeps its name, bank transactions,
  # Imports, Filing rules and their setting; its Default CSV format is cleared, since a synced Account takes no Import, and one that the bank had stopped sharing
  # is shared. One from a disconnected connection moves here, and that connection is deleted once it has no Accounts: it has no token, so no Item to remove.
  # Run inside the caller's lock. The Account is locked and checked again, since it may have been connected since the page was checked, which raises Unlinkable.
  def self.link_account(connection, choice, plaid_account)
    target = choice.link_target
    account = connection.budget.accounts.linkable.lock("FOR UPDATE OF budget_accounts").find_by(id: target.id)
    raise Unlinkable, target.name unless account

    old_connection = account.bank_connection
    account.update!(bank_connection: connection, external_account_id: plaid_account.id, external_name: plaid_account.name || choice.shared_account.name,
      external_mask: plaid_account.mask, read_from: choice.link_read_from, default_csv_format: nil, unshared_at: nil)
    old_connection.destroy! if old_connection && !Budget::Account.exists?(bank_connection_id: old_connection.id)
    account
  end

  # What a notice says of the Accounts that were linked onto: they keep what they had, and are synced from `from` now.
  def self.linked_sentence(accounts, from)
    return if accounts.empty?

    one = accounts.one?
    "#{accounts.map(&:name).to_sentence} #{one ? "keeps its" : "keep their"} bank transactions and #{one ? "is" : "are"} synced from #{from} now."
  end

  def self.call(...)
    new(...).call
  end

  def initialize(budget:, link:, choices:)
    @budget = budget
    @link = link
    @choices = choices
  end

  def call
    return refused(DEADLINE) if @link.expired?
    return invalid unless choices_valid?

    if (account = already_connected_account)
      return refused("#{@link.institution_name} is already connected, so nothing new was connected. " \
        "To sync more of its accounts, or if it stopped syncing, use Choose accounts or Reconnect on #{account.name}.")
    end

    exchange = PlaidApi.client.exchange_public_token(@link.public_token)
    connect(exchange)
  rescue PlaidApi::Error => error
    refused("Nothing was connected. #{error.message}")
  end

  private
    def chosen
      @choices.select(&:connecting?)
    end

    # Each choice is checked as the Account it would make would be, with a Plaid connection that isn't made yet, and at least one account becomes an Account
    # or is linked onto one.
    def choices_valid?
      valid = self.class.check_choices(@choices) { build_account(it) }
      chosen.any? && valid
    end

    def build_account(choice)
      @budget.accounts.new(name: choice.name, read_from: choice.read_from) do |account|
        account.bank_connection = @budget.bank_connections.new(provider: Budget::BankConnection::PLAID)
      end
    end

    # The Account of a live Plaid connection at the same bank whose Plaid name and mask are one of the shared accounts', which means this is a login the budget
    # already has. A connection that was disconnected is a later ticket's to link onto, so it's no reason to refuse. A missing mask equals only another missing one.
    # Both sides are read as PendingPlaidLink reads what Link sends, so a name stored from Plaid's answer compares equal to the same name from the browser.
    def already_connected_account
      shared = @link.accounts.map { [ it.name, it.mask ] }

      live_connections_at_this_bank.flat_map { it.accounts.sort_by { |account| account.name.downcase } }
        .find { shared.include?([ PendingPlaidLink.clean(it.external_name), PendingPlaidLink.clean(it.external_mask) ]) }
    end

    def live_connections_at_this_bank
      @budget.bank_connections.plaid.where(institution_id: @link.institution_id).includes(:accounts).reject(&:disconnected?)
    end

    # From here there's an Item at Plaid, which is removed when anything stops it being connected.
    def connect(exchange)
      answer = PlaidApi.client.accounts(exchange.access_token)
      known = answer.accounts.index_by(&:id)

      unless chosen.all? { known.key?(it.shared_account.id) }
        return remove(exchange, refused("Nothing was connected, since the accounts chosen weren't the ones #{@link.institution_name} shared. Connect again to choose them."))
      end

      kept, left_out = chosen.partition { known.fetch(it.shared_account.id).in_currency?(@budget.currency) }
      return remove(exchange, refused("Nothing was connected, since every account chosen is in another currency.")) if kept.empty?

      connection, accounts = save(exchange, answer, kept.map { [ it, known.fetch(it.shared_account.id) ] })
      notice = [ "Connected #{connection.name}. Its bank transactions arrive within the hour.",
                 self.class.linked_sentence(accounts.select.with_index { |_, index| kept[index].linking? }, "it"),
                 *left_out.map { "#{known.fetch(it.shared_account.id).name || it.shared_account.name} was left out: it's in #{known.fetch(it.shared_account.id).currency || "another currency"}." } ].compact
      Result.new(status: :connected, connection: connection, accounts: accounts, notice: notice.join(" "), alert: nil, choices: @choices, error: nil)
    rescue PlaidApi::Error => error
      remove(exchange, refused("Nothing was connected. #{error.message}"))
    rescue Unlinkable => error
      remove(exchange, refused("Nothing was connected, since #{error.message} can't be linked onto any more. Connect again to choose."))
    rescue ActiveRecord::RecordInvalid => error
      remove(exchange, refused("Nothing was connected. #{error.record.errors.full_messages.to_sentence}."))
    rescue ActiveRecord::RecordNotUnique
      # Another request made the same connection or Account between the check and the insert, which only the unique indexes see.
      remove(exchange, refused("Nothing was connected, since another request connected it a moment ago."))
    rescue StandardError
      # Anything else is a failure of Budgie's own, which is raised as it is, but the Item it exchanged isn't left at Plaid.
      remove(exchange, nil)
      raise
    end

    def save(exchange, answer, pairs)
      @budget.with_lock do
        connection = @budget.bank_connections.create!(provider: Budget::BankConnection::PLAID, login_id: exchange.item_id,
          login_name: answer.institution_name || @link.institution_name, institution_id: answer.institution_id || @link.institution_id, access_token: exchange.access_token)
        accounts = pairs.map do |choice, plaid_account|
          choice.linking? ? self.class.link_account(connection, choice, plaid_account) : self.class.create_account(connection, choice, plaid_account)
        end
        [ connection, accounts ]
      end
    end

    # Asks Plaid to remove the Item, so a connection that wasn't kept doesn't go on at Plaid, and gives back `result`. If Plaid can't be asked, that's logged with the
    # Item's id and never the token, and the person is told what they'd have been told anyway: nothing was connected.
    def remove(exchange, result)
      PlaidApi.client.remove_item(exchange.access_token)
      result
    rescue PlaidApi::Error => error
      Rails.logger.error "Couldn't remove Plaid Item #{exchange.item_id}: #{error.class}: #{error.message}"
      result
    end

    def invalid
      Result.new(status: :invalid, connection: nil, accounts: [], notice: nil, alert: nil, choices: @choices, error: (NONE_CHOSEN if chosen.none?))
    end

    def refused(alert)
      Result.new(status: :refused, connection: nil, accounts: [], notice: nil, alert: alert, choices: @choices, error: nil)
    end
end
