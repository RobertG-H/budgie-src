# The page after Plaid Link (ADR 0018): each account the person shared, and what it becomes, a new Account, linked onto an Account that's there, or left out. It's for connecting a bank, where submitting it
# connects (ConnectPlaid, which runs the checks in order and exchanges the public token only once they pass), and for Choose accounts on a bank that's already
# connected, where it lists only the selected accounts that aren't Accounts yet and Save saves (ChoosePlaidAccounts). Cancel keeps nothing. What Link gave back is in
# the session (PendingPlaidLink), for this budget only, so another budget's is a 404, and it's forgotten once the choice is submitted, on Cancel, and once 30 minutes
# have passed since Link finished.
class PlaidChoicesController < ApplicationController
  include PlaidLinking

  before_action :set_link

  # Choose accounts reads the connection's token, which can't be read once the key it was kept under is lost.
  rescue_from ActiveRecord::Encryption::Errors::Decryption do
    refuse("Nothing was changed, since Budgie can't read the saved connection to #{@link.institution_name}.")
  end

  def show
    return refuse(@chooser ? ChoosePlaidAccounts::DEADLINE : ConnectPlaid::DEADLINE) if @link.expired?

    @choices = @chooser ? @chooser.choices : ConnectPlaid.choices(Current.budget, @link)
  rescue PlaidApi::Error => error
    refuse("Nothing was changed. #{error.message}")
  end

  def create
    @chooser ? save : connect
  end

  def destroy
    forget_pending_link
    redirect_to return_path, status: :see_other, notice: (@chooser ? "Nothing was changed." : "Nothing was connected.")
  end

  private
    # Nothing waiting to be connected is back to the Accounts page, where Connect a bank starts again. Choose accounts is for a connection of the budget's that's
    # still there.
    def set_link
      @link = pending_link
      return redirect_to(accounts_path, alert: "Nothing is waiting to be connected. Connect a bank to choose its accounts.") if @link.nil?

      raise ActiveRecord::RecordNotFound unless @link.for?(Current.budget)
      return unless @link.update?

      @account = Current.budget.accounts.find_by(id: @link.account_id)
      connection = Current.budget.bank_connections.plaid.find_by(id: @link.connection_id)
      return refuse("Nothing was changed, since that bank isn't connected any more.") if connection.nil?

      @chooser = ChoosePlaidAccounts.new(connection: connection, link: @link)
    end

    def connect
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

    def save
      result = @chooser.call(@chooser.choices(choice_params))

      if result.invalid?
        @choices = result.choices
        render :show, status: :unprocessable_content
      elsif result.saved?
        forget_pending_link
        redirect_to return_path, notice: result.notice
      else
        refuse(result.alert)
      end
    rescue PlaidApi::Error => error
      refuse("Nothing was changed. #{error.message}")
    end

    # Each account's choice, by its place in the list. `budget_id`, the connection and the Plaid ids are never params, and an Account to link onto is only ever
    # one ConnectPlaid offers.
    def choice_params
      params.fetch(:plaid_choice, {}).permit(accounts: [ :becomes, :name, :read_from, :link_read_from ])[:accounts]
    end

    # Choose accounts goes back to the Account it was started from, while it's there; connecting goes to the Accounts page.
    def return_path
      @account ? account_path(@account) : accounts_path
    end

    def refuse(alert)
      forget_pending_link
      redirect_to return_path, status: :see_other, alert: alert
    end
end
