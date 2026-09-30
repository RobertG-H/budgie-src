module Dev
  # The theme's colours and the base components on one page, drawn from static sample data, so the design can
  # be checked without signing in or having a budget. See DESIGN.md.
  class StyleguideController < BaseController
    def show
      # Never saved. It only gives `money` a currency to format in.
      @budget = Budget.new(currency: "USD")
    end
  end
end
