require "rails_helper"
# What Solid Queue reads a recurring task's schedule with.
require "fugit"

# The hourly sync: every connection that can be synced is, in turn, and one that fails doesn't hold up the ones after it (ADR 0016). Specs never reach Splitwise.
RSpec.describe SyncBankConnectionsJob, type: :job do
  # A budget with a connected Splitwise Account, signed in as a user of its own, with the expense `dinner` for them.
  def connected_budget(user_id:, token:)
    budget = create(:budget, currency: "CAD")
    connection = create(:budget_bank_connection, budget: budget, login_id: user_id, access_token: token, read_from: Date.new(2026, 10, 1))
    account = create(:budget_account, :synced, budget: budget, bank_connection: connection)
    splitwise.signs_in("code-#{user_id}", as: Splitwise::Person.new(id: user_id, name: "Person #{user_id}"), token: token)
    [ connection, account ]
  end

  before { splitwise.expense(1, "Dinner", net_balance: "-5.00", date: "2026-10-03") }

  # What was logged while the block ran.
  def log_during
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  it "syncs every connection that can be synced" do
    _, first = connected_budget(user_id: "1", token: "token-1")
    _, second = connected_budget(user_id: "2", token: "token-2")

    described_class.perform_now

    expect(first.bank_transactions.count).to eq(1)
    expect(second.bank_transactions.count).to eq(1)
  end

  it "skips a connection that needs reconnecting, until it's reconnected, and one that's disconnected, without asking Splitwise about either" do
    stuck, stuck_account = connected_budget(user_id: "1", token: "token-1")
    stuck.needs_reconnect!
    gone, gone_account = connected_budget(user_id: "2", token: "token-2")
    gone.disconnect!
    _, working_account = connected_budget(user_id: "3", token: "token-3")

    described_class.perform_now

    expect(splitwise.expense_requests.map { |request| request[:token] }).to eq([ "token-3" ])
    expect([ stuck_account, gone_account ].map { |account| account.bank_transactions.count }).to eq([ 0, 0 ])
    expect(working_account.bank_transactions.count).to eq(1)

    stuck.reconnect!(access_token: "token-1", login_name: "Person 1")
    described_class.perform_now

    expect(stuck_account.bank_transactions.count).to eq(1)
  end

  it "finds out a token has stopped working, and says so for the person, without failing the run" do
    revoked, account = connected_budget(user_id: "1", token: "token-1")
    splitwise.revoke("token-1")
    _, other = connected_budget(user_id: "2", token: "token-2")

    expect { described_class.perform_now }.not_to raise_error

    expect(revoked.reload).to be_needs_reconnect
    expect(account.bank_transactions).to be_empty
    expect(other.bank_transactions.count).to eq(1)
  end

  it "carries on past a connection that Splitwise is limiting, which isn't a failure, and tries it again next time" do
    limited, account = connected_budget(user_id: "1", token: "token-1")
    _, other = connected_budget(user_id: "2", token: "token-2")
    splitwise.fails_at_offset(0, Splitwise::RateLimited.new("Splitwise is limiting how often Budgie can ask."))

    expect { described_class.perform_now }.not_to raise_error

    expect(account.bank_transactions).to be_empty
    expect(other.bank_transactions.count).to eq(1)
    expect(limited.reload).to have_attributes(needs_reconnect: false, sync_cursor: nil)
  end

  describe "when one fails" do
    let!(:broken) { connected_budget(user_id: "1", token: "token-1") }
    let!(:other) { connected_budget(user_id: "2", token: "token-2") }

    before do
      broken_id = broken.first.id
      allow(SyncSplitwise).to receive(:call).and_wrap_original do |original, connection|
        raise ActiveRecord::StatementInvalid, "the database said no" if connection.id == broken_id

        original.call(connection)
      end
    end

    it "still syncs the connections after it" do
      expect { described_class.perform_now }.to raise_error(ActiveRecord::StatementInvalid)

      expect(other.last.bank_transactions.count).to eq(1)
    end

    it "fails once the rest are done, logging the connection's id and why, so it isn't missed, and never the token" do
      log = log_during { expect { described_class.perform_now }.to raise_error(ActiveRecord::StatementInvalid, "the database said no") }

      expect(log).to include("connection #{broken.first.id}", "the database said no")
      expect(log).not_to include("token-1")
    end
  end

  it "fails the run, after the rest are done, for a failure that isn't a rejected sign-in or a limit, such as Splitwise being down" do
    _, down = connected_budget(user_id: "1", token: "token-1")
    _, other = connected_budget(user_id: "2", token: "token-2")
    splitwise.fails_at_offset(0, Splitwise::Error.new("Splitwise couldn't be reached."))

    log = log_during { expect { described_class.perform_now }.to raise_error(Splitwise::Error, "Splitwise couldn't be reached.") }

    expect(log).to include("Splitwise couldn't be reached.")
    expect(down.bank_transactions).to be_empty
    expect(other.bank_transactions.count).to eq(1)
  end

  it "does nothing where Splitwise isn't set up, since a token can't be read there" do
    _, account = connected_budget(user_id: "1", token: "token-1")
    Splitwise.client = SplitwiseFake.new(configured: false)

    described_class.perform_now

    expect(account.bank_transactions).to be_empty
  end

  describe "its entry in config/recurring.yml" do
    let(:entry) { Rails.application.config_for(:recurring, env: "production").fetch(:sync_bank_connections) }

    it "runs this job, in production, which covers testing as well" do
      expect(entry[:class].constantize).to eq(described_class)
    end

    it "runs every hour" do
      schedule = Fugit.parse(entry[:schedule])
      first = schedule.next_time(Time.utc(2026, 10, 1, 3, 0, 1))
      second = schedule.next_time(first + 1)

      expect(second - first).to eq(1.hour)
    end
  end
end
