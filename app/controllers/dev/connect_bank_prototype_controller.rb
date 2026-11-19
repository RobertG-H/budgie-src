# PROTOTYPE (#148), throwaway: lives only on the branch prototype/connect-bank-148, never on main.
#
# Three variants of the Connect a bank flow, switchable via `?variant=A|B|C`, on one dev-only route,
# `/dev/prototype/connect-bank/:screen`, with a floating bar to switch variant and screen. The question is
# where the connection-level actions (Sync now, Reconnect, Choose accounts, Disconnect, Connect again) sit now
# that one connection has several Accounts, and what the choice page after Plaid Link looks like.
#
# Everything is stub data in memory: nothing reads or writes the database, and every button is a link to
# another screen of the prototype. It renders inside the real layout (header, sections) so it's judged next
# to the rest of the app. Plaid connections don't exist yet, so this can't be a `?variant=` on /accounts.
module Dev
  class ConnectBankPrototypeController < ApplicationController
    # Development only, as Dev::BaseController is, but signed in, so the real header and budget are there.
    prepend_before_action { head :not_found unless Rails.env.development? }

    VARIANTS = {
      "A" => "On each Account",
      "B" => "Grouped on Accounts",
      "C" => "A connection page"
    }.freeze

    SCREENS = {
      "accounts" => "Accounts",
      "accounts-expired" => "Accounts, after waiting past 30 minutes",
      "accounts-duplicate" => "Accounts, after a duplicate connection",
      "account-td" => "Account: TD chequing (connected)",
      "account-unshared" => "Account: TD Visa (no longer shared)",
      "account-cibc" => "Account: CIBC Visa (needs reconnect)",
      "account-wealthsimple" => "Account: Wealthsimple (connection removed)",
      "connection-td" => "Connection page: TD (variant C)",
      "connection-cibc" => "Connection page: CIBC (variant C)",
      "choose-new" => "Choice page: connecting TD",
      "choose-relink" => "Choice page: connecting Wealthsimple again",
      "choose-more" => "Choice page: Choose accounts on TD"
    }.freeze

    Connection = Data.define(:key, :name, :short_name, :state, :synced_ago, :account_keys) do
      def connected? = state == :connected
      def needs_reconnect? = state == :needs_reconnect
      def removed? = state == :removed
    end

    Account = Data.define(:key, :name, :connection_key, :shared, :read_from, :mask, :plaid_name, :count, :latest_row) do
      def synced? = connection_key.present?
      def csv? = connection_key.nil?
    end

    # What Link hands back for one shared account, before it's anything in Budgie.
    PlaidAccount = Data.define(:id, :plaid_name, :mask, :subtype, :currency, :start, :link_target)

    def show
      @variant = VARIANTS.key?(params[:variant]) ? params[:variant] : "A"
      @screen = SCREENS.key?(params[:screen]) || params[:screen] == "account-savings" ? params[:screen] : "accounts"
      # Stub: a CAD budget, since the banks are Canadian (the seeded dev budget is USD, which the header still says).
      @budget = Budget.new(currency: "CAD")
      build_stub_data

      case @screen
      when "accounts-expired"
        flash.now[:alert] = "Nothing was connected, since the accounts weren't chosen within 30 minutes. Connect again to choose them."
      when "accounts-duplicate"
        flash.now[:alert] = "TD Canada Trust is already connected with TD Every Day Chequing ••4821, so nothing was connected. " \
          "Reconnect it, or use Choose accounts to add another of its accounts."
      end

      # What a stubbed action would have said. Every button is a link here, carrying `did`.
      notice = {
        "sync" => "Synced from TD Canada Trust: 4 new, 1 changed.",
        "connected" => "Connected TD Canada Trust: 3 new Accounts, 1 linked.",
        "reconnected" => "Reconnected CIBC. Its Accounts sync again from where they stopped.",
        "chose" => "TD Unlimited Line of Credit is now an Account, synced from TD Canada Trust.",
        "disconnected" => "Disconnected TD Canada Trust. Its 3 Accounts keep their bank transactions.",
        "date" => "TD Chequing now reads from Mar 1, 2026. The next sync reads every bank transaction dated from it again."
      }[params[:did]]
      flash.now[:notice] = notice if notice

      @account = @accounts.fetch(@screen.delete_prefix("account-")) if @screen.start_with?("account-")
      @connection = @connections.fetch(@screen.delete_prefix("connection-")) if @screen.start_with?("connection-")
      @choice = choice_for(@screen) if @screen.start_with?("choose-")

      render "dev/connect_bank_prototype/show"
    end

    private
      def build_stub_data
        @connections = {
          "td" => Connection.new("td", "TD Canada Trust", "TD", :connected, "12 minutes", %w[td unshared savings]),
          "cibc" => Connection.new("cibc", "CIBC", "CIBC", :needs_reconnect, "2 days", %w[cibc]),
          "wealthsimple" => Connection.new("wealthsimple", "Wealthsimple", "Wealthsimple", :removed, "3 weeks", %w[wealthsimple])
        }

        @accounts = {
          "td" => Account.new("td", "TD Chequing", "td", true, Date.new(2026, 3, 14), "4821", "TD Every Day Chequing Account", 412, Date.new(2026, 11, 18)),
          "savings" => Account.new("savings", "TD High Interest Savings Account", "td", true, Date.new(2025, 1, 2), "0937", "TD High Interest Savings Account", 23, Date.new(2026, 11, 1)),
          "unshared" => Account.new("unshared", "TD Aeroplan Visa", "td", false, Date.new(2025, 1, 2), "5510", "TD Aeroplan Visa Infinite Card", 288, Date.new(2026, 10, 2)),
          "cibc" => Account.new("cibc", "CIBC Dividend Visa", "cibc", true, Date.new(2025, 1, 2), "6604", "CIBC Dividend Visa Infinite Card", 196, Date.new(2026, 11, 16)),
          "wealthsimple" => Account.new("wealthsimple", "Wealthsimple Cash", "wealthsimple", true, Date.new(2025, 1, 2), "3301", "Cash", 74, Date.new(2026, 10, 28)),
          "amex" => Account.new("amex", "Amex Cobalt", nil, nil, nil, nil, nil, 133, Date.new(2026, 11, 12)),
          "tangerine" => Account.new("tangerine", "Tangerine Chequing", nil, nil, nil, nil, nil, 0, nil)
        }

        # The real Splitwise Account, which stays as it is, shown as a plain row so the list looks lived in.
        @splitwise = { name: "Splitwise", detail: "Synced from Splitwise. 57 bank transactions" }
      end

      def choice_for(screen)
        # Link targets: CSV Accounts and a removed connection's Accounts, never a live connection's.
        targets = [ @accounts["amex"], @accounts["tangerine"], @accounts["wealthsimple"] ]
        case screen
        when "choose-new"
          {
            connection: "TD Canada Trust", short: "TD", mode: :new,
            targets: targets + [ Account.new("tdcsv", "TD Chequing (CSV)", nil, nil, nil, nil, nil, 380, Date.new(2026, 11, 14)) ],
            accounts: [
              PlaidAccount.new("p1", "TD Every Day Chequing Account", "4821", "Chequing", "CAD", :new, nil),
              PlaidAccount.new("p2", "TD High Interest Savings Account", "0937", "Savings", "CAD", :new, nil),
              PlaidAccount.new("p3", "TD Aeroplan Visa Infinite Card", "5510", "Credit card", "CAD", :new, nil),
              PlaidAccount.new("p4", "TD U.S. Daily Interest Account", "7702", "Savings", "USD", :leave, nil)
            ]
          }
        when "choose-relink"
          {
            connection: "Wealthsimple", short: "Wealthsimple", mode: :relink,
            targets: targets,
            accounts: [
              PlaidAccount.new("p1", "Cash", "3301", "Cash", "CAD", :link, "wealthsimple"),
              PlaidAccount.new("p2", "Credit card", "8890", "Credit card", "CAD", :new, nil)
            ]
          }
        when "choose-more"
          {
            connection: "TD Canada Trust", short: "TD", mode: :more,
            targets: targets,
            accounts: [
              PlaidAccount.new("p5", "TD Unlimited Line of Credit", "1180", "Line of credit", "CAD", :new, nil),
              PlaidAccount.new("p4", "TD U.S. Daily Interest Account", "7702", "Savings", "USD", :leave, nil)
            ]
          }
        end
      end

      helper_method def proto_path(screen, did: nil, variant: @variant)
        connect_bank_prototype_path(screen: screen, variant: variant, did: did)
      end

      helper_method def disconnect_confirm(connection)
        count = accounts_of(connection).size
        "Disconnect #{connection.name}? Budgie asks Plaid to remove the connection for good. " \
          "Its #{count} #{"Account".pluralize(count)} keep their bank transactions, but nothing new comes in. " \
          "Connecting #{connection.short_name} again uses up another of Plaid's connections."
      end

      helper_method def connection_of(account)
        @connections[account.connection_key]
      end

      helper_method def accounts_of(connection)
        connection.account_keys.map { @accounts.fetch(it) }
      end

      helper_method def default_name(choice, plaid_account)
        "#{choice[:short]} #{plaid_account.plaid_name}".sub(/\ATD TD /, "TD ")
      end
  end
end
