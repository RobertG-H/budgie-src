# Choose accounts on a bank that's already connected (ADR 0018): the person has been through Plaid Link's update mode with account selection, which keeps the Item and
# its account ids and gives back the whole selection, every account now shared. Then:
#
# - each selected account that isn't an Account yet becomes a new Account, is linked onto an Account that's there or is left out, as on Connect, on the same page
#   (`choices`). An account in another
#   currency can only be left out, which this can say before anything is saved, since the connection already has its token and `/accounts/get` gives the currency;
# - an Account whose account isn't selected any more is no longer shared (`unshared_at`): it keeps its bank transactions and stays synced, and gets nothing new;
# - an Account that was no longer shared and is selected again is shared again.
#
# Making an Account, linking onto one or sharing one again maps an account, which resets the connection's cursor, so the next sync reads every transaction again: each is matched by
# its id, so nothing comes in twice. Leaving everything out maps nothing and resets nothing. It's all one database transaction holding the connection's row lock,
# which a sync holds while it runs, so the cursor can't be reset under a sync that would then keep its own. Every account it saves must be one `/accounts/get` has,
# and what's stored about one comes from there. It knows nothing of sessions or redirects: PlaidChoicesController does.
class ChoosePlaidAccounts
  # What came of it: `saved?` with a notice, `invalid?` with the choices and their errors for the page to say, or `refused?` with an alert, when nothing was changed.
  Result = Data.define(:status, :notice, :alert, :choices) do
    def saved? = status == :saved
    def invalid? = status == :invalid
    def refused? = status == :refused
  end

  DEADLINE = "Nothing was changed, since the accounts weren't chosen within 30 minutes. Choose accounts again.".freeze

  attr_reader :connection, :link

  def initialize(connection:, link:)
    @connection = connection
    @link = link
  end

  # The accounts Link says are selected that aren't an Account of the connection yet, which are the ones there's a choice to make about.
  def new_accounts
    mapped = connection.accounts.pluck(:external_account_id)
    link.accounts.reject { mapped.include?(it.id) }
  end

  # The Accounts whose account isn't selected any more and is still shared, which saving stops sharing.
  def deselected_accounts
    selected = link.accounts.map(&:id)
    connection.accounts.shared.alphabetical.reject { selected.include?(it.external_account_id) }
  end

  # The choices for the new accounts, as ConnectPlaid's, and an account Plaid says is in another currency left out, whatever was sent for it. Asks Plaid, so it
  # raises PlaidApi::Error when Plaid can't say.
  def choices(params = nil)
    currency = connection.budget.currency
    ConnectPlaid.choices(connection.budget, link, params, only: new_accounts).each do |choice|
      plaid_account = known[choice.shared_account.id]
      next if plaid_account.nil? || plaid_account.in_currency?(currency)

      choice.becomes = ConnectPlaid::Choice::LEAVE
      choice.left_out_reason = "It's in #{plaid_account.currency || "another currency"} and your budget is in #{currency}, so it can only be left out."
    end
  end

  def call(choices)
    return refused(DEADLINE) if link.expired?
    return refused(gone) if connection.disconnected?
    return invalid(choices) unless ConnectPlaid.check_choices(choices) { build_account(it) }

    selected = link.accounts.map(&:id)
    unless selected.all? { known.key?(it) }
      return refused("Nothing was changed, since the accounts chosen weren't the ones #{connection.name} shares. Choose accounts again.")
    end

    save(choices.select { it.connecting? && !it.left_out? }, selected)
  rescue ConnectPlaid::Unlinkable => error
    refused("Nothing was changed, since #{error.message} can't be linked onto any more. Choose accounts again.")
  rescue PlaidApi::Error => error
    refused("Nothing was changed. #{error.message}")
  rescue ActiveRecord::RecordInvalid => error
    refused("Nothing was changed. #{error.record.errors.full_messages.to_sentence}.")
  rescue ActiveRecord::RecordNotUnique
    refused("Nothing was changed, since another request saved them a moment ago.")
  end

  private
    # What Plaid says the Item's accounts are, by id: the truth about which accounts there are, and their currency, name and mask. Asked once.
    def known
      @known ||= PlaidApi.client.accounts(connection.access_token).accounts.index_by(&:id)
    end

    def build_account(choice)
      connection.budget.accounts.new(name: choice.name, read_from: choice.read_from, bank_connection: connection)
    end

    def save(chosen, selected)
      added = linked = reshared = unshared = nil

      connection.with_lock do
        return refused(gone) if connection.disconnected?

        accounts = connection.accounts.to_a
        added = chosen.reject(&:linking?).map { ConnectPlaid.create_account(connection, it, known.fetch(it.shared_account.id)) }
        linked = chosen.select(&:linking?).map { ConnectPlaid.link_account(connection, it, known.fetch(it.shared_account.id)) }
        reshared = accounts.select { it.unshared? && selected.include?(it.external_account_id) }
        unshared = accounts.select { !it.unshared? && !selected.include?(it.external_account_id) }

        Budget::Account.where(id: reshared).update_all(unshared_at: nil, updated_at: Time.current) if reshared.any?
        Budget::Account.where(id: unshared).update_all(unshared_at: Time.current, updated_at: Time.current) if unshared.any?
        # Update mode signed in to the bank again and Plaid has just answered, so the connection works, whatever a sync found before.
        connection.clear_needs_reconnect! if connection.needs_reconnect?
        connection.forget_sync_cursor! if added.any? || linked.any? || reshared.any?
      end

      Result.new(status: :saved, notice: notice(added, linked, reshared, unshared), alert: nil, choices: [])
    end

    def notice(added, linked, reshared, unshared)
      sentences = []
      if added.any?
        sentences << "Added #{added.map(&:name).to_sentence} from #{connection.name}. #{added.one? ? "Its" : "Their"} bank transactions arrive within the hour."
      end
      sentences << ConnectPlaid.linked_sentence(linked, connection.name) if linked.any?
      sentences << "#{reshared.map(&:name).to_sentence} #{reshared.one? ? "is" : "are"} shared again." if reshared.any?
      sentences << "#{unshared.map(&:name).to_sentence} #{unshared.one? ? "is" : "are"} no longer shared, so nothing new comes in." if unshared.any?
      sentences.any? ? sentences.join(" ") : "Nothing changed on #{connection.name}."
    end

    def gone
      "Nothing was changed, since #{connection.name} isn't connected any more."
    end

    def invalid(choices)
      Result.new(status: :invalid, notice: nil, alert: nil, choices: choices)
    end

    def refused(alert)
      Result.new(status: :refused, notice: nil, alert: alert, choices: [])
    end
end
