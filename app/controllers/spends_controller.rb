class SpendsController < ApplicationController
  include MonthScoped
  include ReturnsToOrigin

  before_action :set_spend, only: %i[ edit update destroy ]

  # A Spend can be started for an envelope, named by its id in `envelope`, which an envelope's page does, and without one,
  # which the month view does. An envelope that isn't the budget's is none.
  def new
    @spend = Budget::Spend.new(date: default_date, envelope: Current.budget.envelopes.find_by(id: params[:envelope]))
  end

  def create
    @spend = Budget::Spend.new(spend_params)

    if @spend.save
      redirect_to return_path(month_of(@spend), envelope: @spend.envelope), notice: "Spend added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @spend.update(spend_params)
      redirect_to return_path(month_of(@spend), envelope: @spend.envelope), notice: "Spend updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @spend.destroy!
    redirect_to return_path(month_of(@spend), envelope: @spend.envelope), status: :see_other, notice: "Spend deleted."
  end

  private
    # Found through the user's budget, by way of its envelopes, so another user's Spend is a 404.
    def set_spend
      @spend = Current.budget.spends.find(params[:id])
    end

    # Today if it's in the month the form was opened from, and otherwise the 1st of that month.
    def default_date
      @month.current? ? Date.current : @month.date
    end

    # A Spend goes back to the page for the month it's dated in, since that's where it's listed.
    def month_of(spend)
      Budget::Month.new(Current.budget, spend.date)
    end

    # The envelope is only ever set from the budget's own envelopes, never from the id that was sent: another budget's
    # envelope, or one that doesn't exist, is no envelope, which the Spend refuses. A change that doesn't name an
    # envelope leaves it where it is.
    def spend_params
      permitted = params.expect(spend: [ :envelope_id, :description, :date, :amount, :notes ])
      return permitted unless permitted.key?(:envelope_id)

      permitted.except(:envelope_id).merge(envelope: Current.budget.envelopes.find_by(id: permitted[:envelope_id]))
    end
end
