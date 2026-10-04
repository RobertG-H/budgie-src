# Lists shown a page at a time, newest first, for a list that can have thousands of rows: an Import can bring in 5,000 at once.
# It asks for one row more than a page, which is how it knows there's another page without counting them all.
module Paginated
  extend ActiveSupport::Concern

  PER_PAGE = 50
  # Far past any list, so that a page number that's silly doesn't overflow the database's integers.
  MAX_PAGE = 1_000_000

  included do
    helper_method :page, :more_pages?
  end

  private
    # The page asked for, from 1: anything that isn't one is the first.
    def page
      @page ||= params[:page].to_s.to_i.clamp(1, MAX_PAGE)
    end

    # The rows of one page of `scope`, in the order it's in. Whether there's a page after it is `more_pages?`.
    def paginate(scope)
      rows = scope.limit(PER_PAGE + 1).offset((page - 1) * PER_PAGE).to_a
      @more_pages = rows.size > PER_PAGE
      rows.first(PER_PAGE)
    end

    def more_pages?
      @more_pages
    end
end
