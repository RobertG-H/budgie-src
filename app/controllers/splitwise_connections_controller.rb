# Connecting Splitwise to the budget as an Account (ADR 0016): a form for the Account's name and the date it reads expenses from, then Splitwise's own
# sign-in. Nothing is made here: the connection and its Account are made when the person comes back (SplitwiseCallbacksController).
class SplitwiseConnectionsController < ApplicationController
  include SplitwiseSignIn

  before_action :require_splitwise

  # The Account's name starts as Splitwise, and the date as where the budget's bank transactions start, so that a shared expense the person paid
  # for, whose card charge is already there, gets its share back.
  def new
    @account = new_account(name: "Splitwise", read_from: Budget::Account.default_read_from(Current.budget))
  end

  # The name and the date are checked as they'd be when the Account is made, so a mistake is found before the person is sent to sign in to Splitwise
  # and not after. The Account and its connection are only built, and never saved: what's left of the connection (the login) isn't known yet.
  def create
    @account = new_account(params.expect(account: [ :name, :read_from ]))
    @account.validate

    if @account.errors.include?(:name) || @account.errors.include?(:read_from)
      render :new, status: :unprocessable_content
    else
      send_to_splitwise(name: @account.name, read_from: @account.read_from.to_s)
    end
  end

  private
    # An Account as connecting makes it: with a Splitwise connection, so that it's checked as a synced Account is.
    def new_account(attributes)
      Current.budget.accounts.new(attributes) { |account| account.bank_connection = Current.budget.bank_connections.new(provider: Budget::BankConnection::SPLITWISE) }
    end
end
