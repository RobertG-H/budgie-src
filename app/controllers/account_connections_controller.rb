# What a synced Account is synced from: Reconnect sends the person to sign in to Splitwise again, and the callback gives the same connection a new token
# when it's the same Splitwise user (SplitwiseCallbacksController); Disconnect forgets the token, after removing a bank's Item at Plaid. Neither touches the Account,
# its bank transactions or what they were filed as. The date it reads expenses from can be changed too, which makes the next sync read from it again (Budget::Account#change_read_from).
# It's found through the budget's Accounts, so another user's Account is a 404, and so is an Account that isn't synced.
class AccountConnectionsController < ApplicationController
  include SplitwiseSignIn
  include SyncedAccountScoped
  include PlaidRefusal

  # Reconnect here is Splitwise's: a bank's is Plaid's update mode (AccountConnectionReconnectsController), so for one of its Accounts it's a 404. Disconnect is both's,
  # but a bank's needs Plaid set up here and a token to remove the Item with, and is never a token forgotten without Plaid being told.
  before_action :require_splitwise_connection, only: :create
  before_action :require_splitwise, only: :create
  before_action :require_connected_plaid, only: :destroy, if: -> { @connection.plaid? }

  def create
    send_to_splitwise(account_id: @account.id)
  end

  # Only the Account's date: the login, the token and the budget are never params. Back to the Account's page either way, saying what was wrong when it can't be used.
  def update
    if @account.change_read_from(params.expect(account: [ :read_from ])[:read_from])
      redirect_to account_path(@account), status: :see_other, notice: "Now reading #{@connection.reads} dated from #{helpers.spelled_date(@account.read_from)}. The next sync reads them again."
    else
      redirect_to account_path(@account), status: :see_other, alert: "#{@account.errors.full_messages.to_sentence}."
    end
  end

  # Splitwise's token is forgotten at once. A bank's Item is removed at Plaid first, and Plaid being unreachable, or refusing, changes nothing, so it can be tried again.
  def destroy
    if @connection.plaid?
      @connection.disconnect_from_plaid!
    else
      @connection.disconnect!
    end
    redirect_to account_path(@account), status: :see_other, notice: "Disconnected from #{@connection.name}."
  rescue *PlaidRefusal::REFUSALS => error
    redirect_to account_path(@account), status: :see_other, alert: plaid_refusal(error, "#{@connection.name} wasn't disconnected", @connection.name)
  end
end
