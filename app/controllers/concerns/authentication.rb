module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    # A session that has gone unused for too long is deleted the next time it's presented,
    # so the visitor has to sign in again.
    def find_session_by_cookie
      found = Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]

      if found&.expired?
        found.destroy
        cookies.delete(:session_id)
        nil
      elsif found
        found.record_activity
        found
      end
    end

    def request_authentication
      # Remember page visits only. A form submission can't be repeated by a redirect, and
      # Turbo's hover prefetches would overwrite the page the visitor actually asked for.
      if request.get? && request.headers["X-Sec-Purpose"] != "prefetch"
        session[:return_to_after_authenticating] = request.url
      end

      redirect_to sign_in_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
