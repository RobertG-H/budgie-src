# Editing and deleting a Reallocation to Ready to Assign. Where it goes is fixed once it's saved: delete it and add another.
class ReadyToAssignReallocationsController < ApplicationController
  include Reallocating

  before_action :set_reallocation

  def edit
  end

  def update
    if @reallocation.update(reallocation_params(envelopes: { from_envelope_id: :envelope }))
      redirect_to return_path_for(@reallocation), notice: "Reallocation updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @reallocation.destroy!
    redirect_to return_path_for(@reallocation), status: :see_other, notice: "Reallocation deleted."
  end

  private
    # Found through the user's budget, by way of its envelope, so another user's Reallocation is a 404.
    def set_reallocation
      @reallocation = Current.budget.ready_to_assign_reallocations.find(params[:id])
    end
end
