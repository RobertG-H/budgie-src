# Where a form goes once it's saved, deleted or cancelled: back to the page it was opened from. That page is named
# by the form's `from` param, which can only be one of PAGES, never a URL, so it can't be made to redirect
# somewhere else. Which month the page shows depends on the form: an envelope's is the month it was opened from,
# and a Deposit's is the month it counts toward. See application/_origin_fields.
module ReturnsToOrigin
  extend ActiveSupport::Concern

  PAGES = %w[ month deposits envelope ].freeze

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
      when "deposits" then month_deposits_path(month)
      when "envelope" then envelope ? month_envelope_path(month, envelope) : month_path(month)
      else month_path(month)
      end
    end
end
