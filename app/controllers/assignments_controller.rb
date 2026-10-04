# What's Assigned to an envelope in a month, set in place on the month view. The Assigned cell there is a Turbo Frame
# that swaps between the amount (show) and an input for it (edit), so each action renders just that frame. Saving
# goes back to the month view, which Turbo refreshes in place, so every figure that follows from it updates.
class AssignmentsController < ApplicationController
  include MonthScoped

  before_action :set_envelope

  # The cell as it is on the month view, which is where Cancel goes back to. Asked for from anywhere else, it's the
  # month view itself.
  def show
    return redirect_to(month_path(@month)) unless turbo_frame_request?

    @line = @month.envelope_line(@envelope.id)
  end

  def edit
    @assignment = @envelope.assignments.find_or_initialize_by(month: @month.date)
  end

  # Sets what's Assigned: a positive amount creates or changes it, and blank or 0 deletes it. An amount that's
  # refused puts the input back with the reason, as a Turbo Stream into the cell's frame when the page asked for
  # one, because the form submits to the whole page and the response would otherwise replace all of it.
  def update
    @assignment = @envelope.assign(@month.date, params.expect(assignment: [ :amount ])[:amount])

    if @assignment.errors.empty?
      redirect_to month_view_path, status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  private
    # Scoped to the user's budget, so another user's envelope is a 404.
    def set_envelope
      @envelope = Current.budget.envelopes.find(params[:envelope_id])
    end

    # The month view of the month that was edited. The current month is the home page as well as /months/YYYY-MM, and
    # Turbo only refreshes a page in place, keeping the scroll position, when the redirect is to the address it's
    # already at. So when the form was on the home page, which is where people land, saving goes back to it. Anything
    # else, such as another month, a Referer that's missing, or a home page left open past the end of a month, goes to
    # the month's own address, which is always the right month. It chooses between two paths of the app's own, so
    # the Referer can't send it anywhere else.
    def month_view_path
      @month.current? && request.referer == root_url ? root_path : month_path(@month)
    end
end
