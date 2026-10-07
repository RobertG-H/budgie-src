# Mark reviewed: a person says they've looked at what a Filing rule filed or ignored (ADR 0017), so the bank transaction is no longer to review. It's
# offered on its row wherever the row is, and goes back to the page it was opened from.
class BankTransactionReviewsController < ApplicationController
  include BankTransactionScoped

  def create
    @bank_transaction.mark_reviewed
    redirect_to origin_path, status: :see_other, notice: "Bank transaction marked reviewed."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to origin_path, status: :see_other, alert: refusal.message
  end
end
