# What a synced Account is synced from: Reconnect sends the person to sign in to Splitwise again, and the callback gives the same connection a new token
# when it's the same Splitwise user (SplitwiseCallbacksController); Disconnect forgets the token. Neither touches the Account, its bank transactions or
# what they were filed as. The date it reads expenses from can be changed too, which makes the next sync read from it again (Budget::BankConnection#change_read_from).
# It's found through the budget's Accounts, so another user's Account is a 404, and so is an Account that isn't synced.
class AccountConnectionsController < ApplicationController
  include SplitwiseSignIn

  before_action :set_account
  before_action :require_splitwise, only: :create

  def create
    send_to_splitwise(account_id: @account.id)
  end

  # Only the date: the login, the token and the budget are never params. Back to the Account's page either way, saying what was wrong when it can't be used.
  def update
    if @connection.change_read_from(params.expect(bank_connection: [ :read_from ])[:read_from])
      redirect_to account_path(@account), status: :see_other, notice: "Now reading expenses dated from #{helpers.spelled_date(@connection.read_from)}. The next sync reads them again."
    else
      redirect_to account_path(@account), status: :see_other, alert: "#{@connection.errors.full_messages.to_sentence}."
    end
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
