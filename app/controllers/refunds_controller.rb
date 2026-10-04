class RefundsController < ApplicationController
  include MonthScoped
  include ReturnsToOrigin

  before_action :set_refund, only: %i[ edit update destroy ]

  helper_method :origin_envelope

  # A Refund is started for an envelope, named by its id in `envelope`, which an envelope's page does. An envelope that
  # isn't the budget's is none, and neither is anything but a plain id, so the form starts on a prompt to choose one.
  def new
    @refund = Budget::Refund.new(date: default_date, envelope: Current.budget.envelopes.find_by(id: params[:envelope].to_s))
  end

  def create
    @refund = Budget::Refund.new(refund_params)

    if @refund.save
      redirect_to return_path(month_of(@refund), envelope: @refund.envelope), notice: "Refund added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @refund.update(refund_params)
      redirect_to return_path(month_of(@refund), envelope: @refund.envelope), notice: "Refund updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @refund.destroy!
    redirect_to return_path(month_of(@refund), envelope: @refund.envelope), status: :see_other, notice: "Refund deleted."
  end

  private
    # Found through the user's budget, by way of its envelopes, so another user's Refund is a 404.
    def set_refund
      @refund = Current.budget.refunds.find(params[:id])
    end

    # The envelope whose page Cancel goes back to. A Refund that's saved is still in the envelope it was found in, even when
    # a change of envelope was refused, and a new one is in the envelope the form has chosen, if any.
    def origin_envelope
      @refund.persisted? ? Current.budget.envelopes.find_by(id: @refund.envelope_id_in_database) : @refund.envelope
    end

    # A Refund goes back to the page for the month it's dated in, since that's where it's listed.
    def month_of(refund)
      Budget::Month.new(Current.budget, refund.date)
    end

    # The envelope is only ever set from the budget's own envelopes, never from the id that was sent: another budget's
    # envelope, or one that doesn't exist, is no envelope, which the Refund refuses. A change that doesn't name an
    # envelope leaves it where it is.
    def refund_params
      permitted = params.expect(refund: [ :envelope_id, :description, :date, :amount, :notes ])
      return permitted unless permitted.key?(:envelope_id)

      permitted.except(:envelope_id).merge(envelope: Current.budget.envelopes.find_by(id: permitted[:envelope_id]))
    end
end
