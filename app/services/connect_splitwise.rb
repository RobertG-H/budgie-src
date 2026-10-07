# Finishes connecting Splitwise, once a person has signed in to it and come back with a code (SplitwiseCallbacksController checks the state first).
# It swaps the code for a token, asks Splitwise who the token is for, and then, holding the budget's row lock so that two callbacks can't both
# make the connection:
#
# - a login the budget has already connected is reconnected: the connection gets the new token and the name Splitwise has for the login now, and
#   needs-reconnect is cleared. Its Account and its bank transactions stay, and so does the date it reads from.
# - a login that isn't connected is a new connection, with a new Account of its own, in one database transaction: if either can't be made, neither is.
#   The Account has Filing rules off, so every bank transaction waits for a person (ADR 0016), and its external id is the Splitwise user's id.
#
# `account` is the Account being reconnected, when that's what the person asked for: only its own login can reconnect it, and any other login is
# refused, since there's no name or date to make another Account with. Never anything but a refusal comes back as an exception, and a refusal's
# words never carry the token, the code or what Splitwise answered. It knows nothing of sessions or redirects.
class ConnectSplitwise
  Result = Data.define(:connection, :account, :reconnected, :failure) do
    def success?
      failure.nil?
    end
  end

  def self.call(...)
    new(...).call
  end

  def initialize(budget:, code:, redirect_uri:, name: nil, read_from: nil, account: nil)
    @budget = budget
    @code = code
    @redirect_uri = redirect_uri
    @name = name
    @read_from = read_from
    @account = account
  end

  def call
    token = Splitwise.client.exchange_code(code: @code, redirect_uri: @redirect_uri)
    person = Splitwise.client.current_user(token)

    @budget.with_lock { connect(token, person) }
  rescue Splitwise::Error => error
    failure(error.message)
  rescue ActiveRecord::RecordInvalid => error
    failure(error.record.errors.full_messages.to_sentence + ".")
  end

  private
    def connect(token, person)
      connection = @budget.bank_connections.find_by(provider: "splitwise", login_id: person.id)

      if @account && connection&.id != @account.bank_connection_id
        failure("#{@account.name} is synced from Splitwise as #{@account.bank_connection.login_name}, and that isn't who signed in. " \
          "To sync another Splitwise user, use Connect Splitwise on the Accounts page.")
      elsif connection
        reconnect(connection, token, person)
      else
        create(token, person)
      end
    end

    def reconnect(connection, token, person)
      connection.reconnect!(access_token: token, login_name: person.name)
      Result.new(connection: connection, account: connection.accounts.order(:id).first, reconnected: true, failure: nil)
    end

    def create(token, person)
      connection = @budget.bank_connections.create!(provider: "splitwise", login_id: person.id, login_name: person.name, access_token: token, read_from: @read_from)
      account = @budget.accounts.create!(name: @name, bank_connection: connection, external_account_id: person.id, files_with_rules: false)
      Result.new(connection: connection, account: account, reconnected: false, failure: nil)
    end

    def failure(message)
      Result.new(connection: nil, account: nil, reconnected: false, failure: message)
    end
end
