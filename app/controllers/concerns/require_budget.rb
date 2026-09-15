# Sends a signed-in user who hasn't set up their budget to the setup page, whatever they asked for.
module RequireBudget
  extend ActiveSupport::Concern

  included do
    before_action :require_budget
  end

  class_methods do
    def allow_missing_budget(**options)
      skip_before_action :require_budget, **options
    end
  end

  private
    def require_budget
      redirect_to new_budget_path if Current.user && Current.user.budget.nil?
    end
end
