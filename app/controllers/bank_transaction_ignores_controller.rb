# Ignoring a bank transaction, which Budgie won't file, such as a card payment between a person's own accounts, and un-ignoring it.
# Pairing transfers between Accounts is out of scope, so both sides are ignored separately.
class BankTransactionIgnoresController < ApplicationController
  include ReturnsToOrigin

  before_action :set_bank_transaction

  def create
    @bank_transaction.ignore
    redirect_to return_path(account: @bank_transaction.account), notice: "Bank transaction ignored."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to return_path(account: @bank_transaction.account), alert: refusal.message
  end

  def destroy
    @bank_transaction.unignore
    redirect_to return_path(account: @bank_transaction.account), status: :see_other, notice: "Bank transaction un-ignored."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to return_path(account: @bank_transaction.account), status: :see_other, alert: refusal.message
  end

  private
    # Found through the user's budget, by way of its Account, so another user's bank transaction is a 404.
    def set_bank_transaction
      @bank_transaction = Current.budget.bank_transactions.find(params[:bank_transaction_id])
    end
end
