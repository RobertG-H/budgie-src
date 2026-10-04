# Putting an envelope away, and taking it back. Both go back to the envelope's page for the month the button was on, with
# a notice, and a refusal comes back as an alert there, the way a refused delete does.
class EnvelopeArchivesController < ApplicationController
  include MonthScoped

  before_action :set_envelope

  # Archiving is judged against today's month, whichever month's page it's asked for from.
  def create
    @envelope.archive!
    redirect_to envelope_page, status: :see_other, notice: "Envelope archived."
  rescue Budget::Envelope::Refused => refusal
    redirect_to envelope_page, status: :see_other, alert: refusal.message
  end

  def destroy
    @envelope.unarchive
    redirect_to envelope_page, status: :see_other, notice: "Envelope unarchived."
  end

  private
    # Scoped to the user's budget, so another user's envelope is a 404.
    def set_envelope
      @envelope = Current.budget.envelopes.find(params[:envelope_id])
    end

    def envelope_page
      month_envelope_path(@month, @envelope)
    end
end
