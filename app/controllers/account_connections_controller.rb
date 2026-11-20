# What a synced Account is synced from: Reconnect sends the person to sign in to Splitwise again, and the callback gives the same connection a new token
# when it's the same Splitwise user (SplitwiseCallbacksController); Disconnect forgets the token. Neither touches the Account, its bank transactions or
# what they were filed as. The date it reads expenses from can be changed too, which makes the next sync read from it again (Budget::Account#change_read_from).
# It's found through the budget's Accounts, so another user's Account is a 404, and so is an Account that isn't synced.
class AccountConnectionsController < ApplicationController
  include SplitwiseSignIn
  include SyncedAccountScoped

  # Reconnect and Disconnect are Splitwise's alone for now: a bank's come with Plaid's update mode and `/item/remove`, in later tickets, so for one of its Accounts
  # they're a 404 and never a token forgotten without Plaid being told.
  before_action :require_splitwise_connection, only: %i[ create destroy ]
  before_action :require_splitwise, only: :create

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

  def destroy
    @connection.disconnect!
    redirect_to account_path(@account), status: :see_other, notice: "Disconnected from #{@connection.provider_name}."
  end
end
