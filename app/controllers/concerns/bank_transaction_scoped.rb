# What the controllers that act on one bank transaction have in common: they find it through the user's budget, by way of its
# Account, so another user's is a 404, and they go back to the page the form was opened from, which is the Bank transactions page or the
# Account's page (ReturnsToOrigin), or the Account's page when it isn't known.
module BankTransactionScoped
  extend ActiveSupport::Concern

  included do
    include ReturnsToOrigin

    before_action :set_bank_transaction
    helper_method :origin_path
  end

  private
    def set_bank_transaction
      @bank_transaction = Current.budget.bank_transactions.find(params[:bank_transaction_id])
    end

    def origin_path
      return_path(account: @bank_transaction.account)
    end
end
