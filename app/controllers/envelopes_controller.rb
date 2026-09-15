class EnvelopesController < ApplicationController
  before_action :set_envelope, only: %i[ edit update destroy ]

  def index
    @envelopes = budget.envelopes.alphabetical
  end

  def new
    @envelope = budget.envelopes.new
  end

  def create
    @envelope = budget.envelopes.new(envelope_params)

    if @envelope.save
      redirect_to envelopes_path, notice: "Envelope created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @envelope.update(envelope_params)
      redirect_to envelopes_path, notice: "Envelope updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @envelope.destroy!
    redirect_to envelopes_path, status: :see_other, notice: "Envelope deleted."
  end

  private
    def budget
      Current.user.budget
    end

    # Scoped to the user's budget, so another user's envelope is a 404.
    def set_envelope
      @envelope = budget.envelopes.find(params[:id])
    end

    def envelope_params
      params.expect(envelope: [ :name, :starting_balance ])
    end
end
