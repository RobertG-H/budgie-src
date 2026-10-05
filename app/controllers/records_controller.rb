# Every Deposit, Spend, Refund and Reallocation of the budget in one list, newest first, for a range of dates, narrowed by Kind and
# by envelope, with what came in and went out over the whole range. A row opens its record's edit page, which brings the person
# back here, to the same filtered page, when it's saved, deleted or cancelled (`from=records`, see ReturnsToOrigin). The filters are one
# nested param, `filter`, so they never collide with `from` or `envelope`, which other pages use.
class RecordsController < ApplicationController
  include Paginated

  def index
    @list = Budget::RecordList.parse(Current.budget, params[:filter])
    flash.now[:alert] = @list.date_range.error unless @list.date_range.valid?

    @records = @list.records(paginate(@list.keys))
    @totals = @list.totals
  end
end
