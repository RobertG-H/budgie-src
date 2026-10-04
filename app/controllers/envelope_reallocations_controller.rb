# Editing and deleting a Reallocation to an envelope. Which envelope it goes to is fixed once it's saved: delete it and add
# another instead.
class EnvelopeReallocationsController < ApplicationController
  include Reallocating

  before_action :set_reallocation

  def edit
  end

  def update
    if @reallocation.update(reallocation_params(envelopes: %i[ from ]))
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
    # Found through the user's budget, by way of the From envelope, so another user's Reallocation is a 404.
    def set_reallocation
      @reallocation = Current.budget.envelope_reallocations.find(params[:id])
    end
end
