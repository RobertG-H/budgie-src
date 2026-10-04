# What's Assigned to an envelope in a month, set in place on the month view. The Assigned cell there is a Turbo Frame
# that swaps between the amount (show) and an input for it (edit), so each action renders just that frame. Saving
# goes back to the month view, which Turbo refreshes in place, so every figure that follows from it updates.
class AssignmentsController < ApplicationController
  include MonthScoped
  include ReturnsToOrigin

  before_action :set_envelope

  # The cell as it is on the month view, which is where Cancel goes back to. Asked for from anywhere else, it's the
  # month view itself.
  def show
    return redirect_to(return_path(@month)) unless turbo_frame_request?

    @line = @month.envelope_line(@envelope.id)
  end

  # Without JavaScript, or asked for outside the frame, the input is a page of its own, and saving still goes back to
  # the month view.
  def edit
    @assignment = @envelope.assignments.find_or_initialize_by(month: @month.date)
  end

  # Sets what's Assigned: a positive amount creates or changes it, and blank or 0 deletes it. An amount that's
  # refused puts the input back with the reason, as a Turbo Stream into the cell's frame when the page asked for
  # one, because the form submits to the whole page and the response would otherwise replace all of it.
  def update
    @assignment = @envelope.assign(@month.date, params.expect(assignment: [ :amount ])[:amount])

    if @assignment.errors.empty?
      redirect_to return_path(@month), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  private
    # Scoped to the user's budget, so another user's envelope is a 404.
    def set_envelope
      @envelope = Current.budget.envelopes.find(params[:envelope_id])
    end
end
