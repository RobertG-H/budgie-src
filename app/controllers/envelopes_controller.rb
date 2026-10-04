class EnvelopesController < ApplicationController
  include MonthScoped
  include ReturnsToOrigin

  before_action :set_envelope, only: %i[ edit update destroy ]

  # An envelope's figures for a month, and the Spends, Refunds and Reallocations dated in it. It's one of the month's own envelope lines, so
  # another user's envelope, or one that doesn't exist, is a 404.
  def show
    @line = @month.envelope_line(params[:id])
    @envelope = @line.envelope
    @spends = @envelope.spends.dated_in(@month.date).newest_first.load
    @refunds = @envelope.refunds.dated_in(@month.date).newest_first.load
    @reallocations = Budget::EnvelopeReallocation.involving(@envelope).dated_in(@month.date).newest_first
      .includes(:from_envelope, :to_envelope).load
  end

  def new
    @envelope = Current.budget.envelopes.new
  end

  def create
    @envelope = Current.budget.envelopes.new(envelope_params)

    if @envelope.save
      redirect_to return_path(@month, envelope: @envelope), notice: "Envelope created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @envelope.update(envelope_params)
      redirect_to return_path(@month, envelope: @envelope), notice: "Envelope updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  # The envelope's own page is gone, so wherever the form was opened from, this goes to the month view. An envelope
  # with records can't be deleted: its page says why, and stays.
  def destroy
    if @envelope.destroy
      redirect_to month_path(@month), status: :see_other, notice: "Envelope deleted."
    else
      redirect_to month_envelope_path(@month, @envelope), status: :see_other, alert: @envelope.errors.full_messages.to_sentence
    end
  end

  private
    # Scoped to the user's budget, so another user's envelope is a 404.
    def set_envelope
      @envelope = Current.budget.envelopes.find(params[:id])
    end

    def envelope_params
      params.expect(envelope: [ :name, :starting_balance ])
    end
end
