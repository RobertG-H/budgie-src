class DepositsController < ApplicationController
  include MonthScoped
  include ReturnsToOrigin

  before_action :set_deposit, only: %i[ edit update destroy ]

  # The Deposits counting toward a month's Ready to Assign, which can include some dated in the month before.
  def index
    @deposits = Current.budget.deposits.for_month(@month.date).newest_first.load
  end

  def new
    @deposit = Current.budget.deposits.new(date: default_date, month: default_date)
  end

  def create
    @deposit = Current.budget.deposits.new(deposit_params)

    if @deposit.save
      redirect_to return_path(month_of(@deposit)), notice: "Deposit added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @deposit.update(deposit_params)
      redirect_to return_path(month_of(@deposit)), notice: "Deposit updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @deposit.destroy!
    redirect_to return_path(month_of(@deposit)), status: :see_other, notice: "Deposit deleted."
  end

  private
    # Scoped to the user's budget, so another user's Deposit is a 404.
    def set_deposit
      @deposit = Current.budget.deposits.find(params[:id])
    end

    # A Deposit goes back to the page for the month it counts toward, since that's where it's listed.
    def month_of(deposit)
      Budget::Month.new(Current.budget, deposit.month)
    end

    def deposit_params
      params.expect(deposit: [ :description, :date, :month, :amount, :notes ])
    end
end
