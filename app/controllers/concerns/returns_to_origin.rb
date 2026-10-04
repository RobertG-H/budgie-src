# Where a form goes once it's saved, deleted or cancelled: back to the page it was opened from. That page is named
# by the form's `from` param, which can only be one of PAGES, never a URL, so it can't be made to redirect
# somewhere else. Which month the page shows depends on the form: an envelope's is the month it was opened from,
# a Deposit's is the month it counts toward, and a Spend's or a Refund's is the month of its date. See application/_origin_fields.
#
# The home page is the month view of the current month at /, as well as at /months/YYYY-MM, and they're two pages to
# Turbo, which only refreshes a page in place when it's sent back to the address it's on. So `home` is a page of its
# own: it goes back to / for the current month, and for any other month, which / no longer shows, to that month.
module ReturnsToOrigin
  extend ActiveSupport::Concern

  PAGES = %w[ home month deposits envelope ].freeze

  included do
    helper_method :origin, :return_path
  end

  private
    def origin
      params[:from].presence_in(PAGES)
    end

    # The path of the page the form was opened from, showing `month`. The envelope's page needs the `envelope`;
    # without one, as for a Deposit, or an envelope that has just been deleted, it's the month view instead.
    def return_path(month, envelope: nil)
      case origin
      when "home" then month.current? ? root_path : month_path(month)
      when "deposits" then month_deposits_path(month)
      when "envelope" then envelope ? month_envelope_path(month, envelope) : month_path(month)
      else month_path(month)
      end
    end
end
