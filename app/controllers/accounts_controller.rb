class AccountsController < ApplicationController
  include Paginated

  before_action :set_account, only: %i[ show edit update destroy ]

  helper_method :more_pages?

  def index
    @accounts = Current.budget.accounts.alphabetical
    @transaction_counts = Current.budget.bank_transactions.group(:account_id).count
  end

  # The Account's bank transactions, a page at a time, newest first, and its latest Import.
  def show
    @bank_transactions = paginate(@account.bank_transactions.newest_first)
    @latest_import = @account.latest_import
  end

  def new
    @account = Current.budget.accounts.new
  end

  def create
    @account = Current.budget.accounts.new(account_params)

    if @account.save
      redirect_to accounts_path, notice: "Account added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @account.update(account_params)
      redirect_to account_path(@account), notice: "Account updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  # An Account with bank transactions can't be deleted: its page says why, and stays.
  def destroy
    if @account.destroy
      redirect_to accounts_path, status: :see_other, notice: "Account deleted."
    else
      redirect_to account_path(@account), status: :see_other, alert: @account.errors.full_messages.to_sentence
    end
  end

  private
    # Found through the user's budget, so another user's Account is a 404.
    def set_account
      @account = Current.budget.accounts.find(params[:id])
    end

    def account_params
      params.expect(account: [ :name ])
    end
end
