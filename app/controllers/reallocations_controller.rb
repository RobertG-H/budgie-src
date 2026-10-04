# The Reallocate form, which makes a Reallocation. Its To decides the table the Reallocation goes in: an envelope, or
# Ready to Assign. Editing and deleting one are per table (EnvelopeReallocationsController and
# ReadyToAssignReallocationsController).
class ReallocationsController < ApplicationController
  include Reallocating

  # A Reallocation is started from an envelope, named by its id in `envelope`, which an envelope's page does. It's the
  # envelope the money leaves, and the form starts on a prompt to choose one when there isn't one, or when it's an archived
  # one, which takes no new records.
  def new
    @reallocation = Budget::EnvelopeReallocation.new(date: default_date, from_envelope: (opened_from unless opened_from&.archived?))
  end

  def create
    @reallocation = if to_ready_to_assign?
      Budget::ReadyToAssignReallocation.new(reallocation_params(envelopes: { from_envelope_id: :envelope }))
    else
      Budget::EnvelopeReallocation.new(reallocation_params(envelopes: { from_envelope_id: :from_envelope, to_envelope_id: :to_envelope }))
    end

    if @reallocation.save
      redirect_to return_path_for(@reallocation), notice: "Reallocation added."
    else
      render :new, status: :unprocessable_content
    end
  end

  private
    def to_ready_to_assign?
      permitted_reallocation[:to_envelope_id] == READY_TO_ASSIGN
    end
end
