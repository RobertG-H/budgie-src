# Connecting a bank through Plaid (ADR 0018), the page after Plaid Link: each account the person shared, and what it becomes, a new Account or left out. Submitting
# it connects (ConnectPlaid, which runs the checks in order and exchanges the public token only once they pass); Cancel keeps nothing. What Link gave back is in the
# session (PendingPlaidLink), for this budget only, so another budget's is a 404, and it's forgotten once the choice is submitted, on Cancel, and once 30 minutes
# have passed since Link finished.
class PlaidChoicesController < ApplicationController
  include PlaidLinking

  before_action :set_link

  def show
    return refuse(ConnectPlaid::DEADLINE) if @link.expired?

    @choices = ConnectPlaid.choices(Current.budget, @link)
  end

  def create
    result = ConnectPlaid.call(budget: Current.budget, link: @link, choices: ConnectPlaid.choices(Current.budget, @link, choice_params))

    if result.invalid?
      @choices = result.choices
      @error = result.error
      render :show, status: :unprocessable_content
    elsif result.connected?
      forget_pending_link
      redirect_to account_path(result.accounts.first), notice: result.notice
    else
      refuse(result.alert)
    end
  end

  def destroy
    forget_pending_link
    redirect_to accounts_path, status: :see_other, notice: "Nothing was connected."
  end

  private
    # Nothing waiting to be connected is back to the Accounts page, where Connect a bank starts again.
    def set_link
      @link = pending_link
      return redirect_to(accounts_path, alert: "Nothing is waiting to be connected. Connect a bank to choose its accounts.") if @link.nil?

      raise ActiveRecord::RecordNotFound unless @link.for?(Current.budget)
    end

    # Each account's choice, by its place in the list. `budget_id`, the connection and the Plaid ids are never params.
    def choice_params
      params.fetch(:plaid_choice, {}).permit(accounts: [ :becomes, :name, :read_from ])[:accounts]
    end

    def refuse(alert)
      forget_pending_link
      redirect_to accounts_path, status: :see_other, alert: alert
    end
end
