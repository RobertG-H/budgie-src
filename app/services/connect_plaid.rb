# Connects a bank once a person has been through Plaid Link and chosen what each account they shared becomes: a new Account, or left out (ADR 0018). Linking
# onto an existing Account comes later. The checks run in this order, and everything before the exchange spends no Item, which on Plaid's Trial is one of ten for good:
#
# 1. the deadline: Plaid's public token lasts 30 minutes from when Link finished;
# 2. the choices: at least one account becomes an Account, and every name and date is one an Account could have (a mistake is said on the page);
# 3. the duplicate check: the same bank as one of the budget's live Plaid connections, with an account whose name and mask are one of that connection's Accounts',
#    is that login again, which is refused and pointed at Reconnect or Choose accounts; the same bank with none of them is a second login, and is allowed;
# 4. the exchange, which makes the Item;
# 5. `/accounts/get`: every account chosen must be one Plaid has (anything else was crafted), an account in another currency is left out, and what's stored about
#    each account comes from here, never from what the browser sent;
# 6. the connection and its Accounts, in one database transaction holding the budget's row lock.
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

  # What one shared account becomes, as the choice page has it: `becomes` is "new" or "leave", and a new Account's `name` and `read_from` go with it. Its errors are
  # an Account's own (its name taken, a date that couldn't be real) on the same fields.
  class Choice
    include ActiveModel::Model
    include ActiveModel::Attributes

    NEW = "new".freeze
    LEAVE = "leave".freeze
    BECOMES = [ NEW, LEAVE ].freeze

    attribute :becomes, :string, default: NEW
    attribute :name, :string
    attribute :read_from, :date
    attr_accessor :shared_account

    def self.human_attribute_name(attribute, options = {})
      { "name" => "Account name", "read_from" => "Date to read from", "becomes" => "Becomes" }.fetch(attribute.to_s) { super }
    end

    def new_account?
      becomes == NEW
    end
  end

  DEADLINE = "Nothing was connected, since the accounts weren't chosen within 30 minutes. Connect again to choose them.".freeze
  NONE_CHOSEN = "Choose at least one account to connect.".freeze

  # The choices for `link`'s accounts: what was sent for each, by its place in the list (`params`, the form's `accounts`), or, for the page as it starts, a new
  # Account each, named for the bank and the account and reading from where the budget's bank transactions start. `params` is what the controller permitted.
  def self.choices(budget, link, params = nil)
    read_from = Budget::Account.default_read_from(budget)

    link.accounts.each_with_index.map do |shared, index|
      sent = params.respond_to?(:to_h) ? params.to_h.with_indifferent_access[index.to_s] : nil
      sent = sent.respond_to?(:slice) ? sent.slice(:becomes, :name, :read_from).to_h.symbolize_keys : {}
      Choice.new(shared_account: shared, becomes: Choice::NEW, name: default_name(link, shared), read_from: read_from, **sent)
    end
  end

  # The bank and the account ("TD Canada Trust Visa Infinite"), unless the account's name already starts with the bank's first word ("TD Every Day Chequing"),
  # which is its letters up to a hyphen or a space, so "Tartan U.S. Dollar" at Tartan-Dominion Bank of Canada isn't named for the bank twice, and "Tartanic" isn't
  # taken for "Tartan".
  def self.default_name(link, shared)
    first_word = link.institution_name.to_s[/\A[[:alnum:]]+/]
    named_for_the_bank = first_word && shared.name.match?(/\A#{Regexp.escape(first_word)}(?![[:alnum:]])/i)
    named_for_the_bank ? shared.name : "#{link.institution_name} #{shared.name}".squish
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
      @choices.select(&:new_account?)
    end

    # Each choice is checked as the Account it would make would be, with a Plaid connection that isn't made yet, so a name that's taken or a date that couldn't be
    # real is said on the page, and two new Accounts can't be given the same name either.
    def choices_valid?
      @choices.each do |choice|
        choice.errors.clear
        choice.errors.add(:becomes, "isn't one of the choices") unless Choice::BECOMES.include?(choice.becomes)
      end

      names = []
      chosen.each do |choice|
        account = build_account(choice)
        account.validate
        account.errors.each { |error| choice.errors.add(error.attribute, error.message) if error.attribute.in?([ :name, :read_from ]) }

        key = account.name.to_s.downcase
        choice.errors.add(:name, "is the same as another account's on this page") if key.present? && names.include?(key) && choice.errors[:name].none?
        names << key
      end

      chosen.any? && @choices.none? { it.errors.any? }
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
                 *left_out.map { "#{known.fetch(it.shared_account.id).name || it.shared_account.name} was left out: it's in #{known.fetch(it.shared_account.id).currency || "another currency"}." } ]
      Result.new(status: :connected, connection: connection, accounts: accounts, notice: notice.join(" "), alert: nil, choices: @choices, error: nil)
    rescue PlaidApi::Error => error
      remove(exchange, refused("Nothing was connected. #{error.message}"))
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
          @budget.accounts.create!(name: choice.name, read_from: choice.read_from, bank_connection: connection, external_account_id: plaid_account.id,
            external_name: plaid_account.name || choice.shared_account.name, external_mask: plaid_account.mask, files_with_rules: true)
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
