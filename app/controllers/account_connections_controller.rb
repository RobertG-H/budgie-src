# What a synced Account is synced from: Reconnect sends the person to sign in to Splitwise again, and the callback gives the same connection a new token
# when it's the same Splitwise user (SplitwiseCallbacksController); Disconnect forgets the token. Neither touches the Account, its bank transactions or
# what they were filed as. It's found through the budget's Accounts, so another user's Account is a 404, and so is an Account that isn't synced.
class AccountConnectionsController < ApplicationController
  include SplitwiseSignIn

  before_action :set_account
  before_action :require_splitwise, only: :create

  def create
    send_to_splitwise(account_id: @account.id)
  end

  def destroy
    @connection.disconnect!
    redirect_to account_path(@account), status: :see_other, notice: "Disconnected from #{@connection.provider_name}."
  end

  private
    def set_account
      @account = Current.budget.accounts.find(params[:account_id])
      @connection = @account.bank_connection or raise ActiveRecord::RecordNotFound
    end
end
