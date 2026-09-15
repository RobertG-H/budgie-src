class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create failure ]

  # Refusals the visitor can act on get their own message; every other reason stays behind the generic one.
  REFUSAL_MESSAGES = {
    not_invited: "Budgie is invite-only. Ask for an invite to sign in."
  }.freeze

  def new
    redirect_to root_path if authenticated?
  end

  # OmniAuth has already completed the provider's side of sign-in when its callback reaches this action.
  def create
    result = SignInWithIdentity.call(AuthProfile.from_omniauth(request.env["omniauth.auth"]))

    if result.success?
      start_new_session_for result.user
      redirect_to after_authentication_url
    else
      refuse_sign_in reason: result.failure_reason, provider: params[:provider]
    end
  end

  # OmniAuth redirects here when the provider's side fails, e.g. the visitor cancelled or the state didn't match.
  def failure
    refuse_sign_in reason: params[:message], provider: params[:strategy]
  end

  def destroy
    terminate_session
    redirect_to sign_in_path, status: :see_other, notice: "You've been signed out."
  end

  private
    def refuse_sign_in(reason:, provider:)
      logger.info "Sign-in refused: #{reason.to_s.inspect} from #{provider.to_s.inspect}"
      redirect_to sign_in_path, alert: REFUSAL_MESSAGES.fetch(reason, "We couldn't sign you in.")
    end
end
