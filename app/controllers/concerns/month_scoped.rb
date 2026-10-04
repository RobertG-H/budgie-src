# Sets @month from the `month` param: a month's URL names it as "2026-09", and so do the forms opened from a month.
# Without the param it's the current month. A param that isn't a month is a 404.
module MonthScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_month
  end

  private
    def set_month
      @month = if params[:month].present?
        Budget::Month.from_param(Current.budget, params[:month]) || raise(ActionController::RoutingError, "Not Found")
      else
        Budget::Month.new(Current.budget, Date.current)
      end
    end
end
