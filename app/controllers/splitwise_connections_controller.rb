# Connecting Splitwise to the budget as an Account (ADR 0016): a form for the Account's name and the date to read expenses from, then Splitwise's own
# sign-in. Nothing is made here: the connection and its Account are made when the person comes back (SplitwiseCallbacksController).
class SplitwiseConnectionsController < ApplicationController
  include SplitwiseSignIn

  before_action :require_splitwise

  # The Account's name starts as Splitwise, and the date as where the budget's bank transactions start, so that a shared expense the person paid
  # for, whose card charge is already there, gets its share back.
  def new
    @account = Current.budget.accounts.new(name: "Splitwise")
    @connection = Current.budget.bank_connections.new(provider: Budget::BankConnection::SPLITWISE, read_from: Budget::BankConnection.default_read_from(Current.budget))
  end

  # The name and the date are checked as they'd be when the Account and the connection are made, so a mistake is found before the person is sent to
  # sign in to Splitwise and not after. Both models are only built, and never saved: what's left of the connection (the login) isn't known yet.
  def create
    @account = Current.budget.accounts.new(params.expect(account: [ :name ]))
    @connection = Current.budget.bank_connections.new(provider: Budget::BankConnection::SPLITWISE, read_from: params.expect(bank_connection: [ :read_from ])[:read_from])
    @account.validate
    @connection.validate

    if @account.errors.include?(:name) || @connection.errors.include?(:read_from)
      render :new, status: :unprocessable_content
    else
      send_to_splitwise(name: @account.name, read_from: @connection.read_from.to_s)
    end
  end
end
