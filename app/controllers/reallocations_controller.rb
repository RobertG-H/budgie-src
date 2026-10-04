# The Reallocate form, which makes a Reallocation. Its To decides the table the Reallocation goes in, and for now every
# To is an envelope; editing and deleting one are per table (EnvelopeReallocationsController).
class ReallocationsController < ApplicationController
  include Reallocating

  # A Reallocation is started from an envelope, named by its id in `envelope`, which an envelope's page does. It's the
  # envelope the money leaves, and the form starts on a prompt to choose one when there isn't one.
  def new
    @reallocation = Budget::EnvelopeReallocation.new(date: default_date, from_envelope: opened_from)
  end

  def create
    @reallocation = Budget::EnvelopeReallocation.new(reallocation_params(envelopes: %i[ from to ]))

    if @reallocation.save
      redirect_to return_path_for(@reallocation), notice: "Reallocation added."
    else
      render :new, status: :unprocessable_content
    end
  end
end
