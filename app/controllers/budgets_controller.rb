# First-run setup: a signed-in user without a budget creates one by choosing its currency.
class BudgetsController < ApplicationController
  allow_missing_budget
  before_action :redirect_to_home, if: -> { Current.budget }

  def new
    @budget = Budget.new
  end

  def create
    @budget = Budget.new(user: Current.user, currency: params.expect(budget: [ :currency ])[:currency])

    if @budget.save
      redirect_to root_path, notice: "Your budget is ready."
    else
      render :new, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique
    # A double submit: the other request already created the budget.
    redirect_to_home
  end

  private
    def redirect_to_home
      redirect_to root_path
    end
end
