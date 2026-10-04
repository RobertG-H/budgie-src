# Ignoring a bank transaction, which Budgie won't file, such as a card payment between a person's own accounts, and un-ignoring it.
# Pairing transfers between Accounts is out of scope, so both sides are ignored separately.
class BankTransactionIgnoresController < ApplicationController
  include BankTransactionScoped

  def create
    @bank_transaction.ignore
    redirect_to origin_path, notice: "Bank transaction ignored."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to origin_path, alert: refusal.message
  end

  def destroy
    @bank_transaction.unignore
    redirect_to origin_path, status: :see_other, notice: "Bank transaction un-ignored."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to origin_path, status: :see_other, alert: refusal.message
  end
end
