# What the controllers for a Reallocation have in common, whichever table it's in: the month it's listed in, the
# envelopes it's looked up through, and where saving, deleting or cancelling goes back to.
#
# A Reallocation is listed on both its envelopes' pages, so a form opened from an envelope's page also carries that
# envelope, as `envelope`. Saving, deleting or cancelling then goes back to that envelope's page for as long as the
# Reallocation is still in or out of it, and to its From envelope's page otherwise, such as after From is changed. Which
# page it goes back to at all is up to `from`, as for any form. See ReturnsToOrigin.
#
# One Reallocate form makes either kind, and the Ready to Assign option of its To field is what says which: it sends
# READY_TO_ASSIGN where an envelope would send its id. It's a value, never a name in a URL or a param key.
module Reallocating
  extend ActiveSupport::Concern

  READY_TO_ASSIGN = "ready-to-assign".freeze

  included do
    include MonthScoped
    include ReturnsToOrigin

    helper_method :opened_from, :cancel_path
  end

  private
    # The envelope whose page the form was opened from, named by its id in `envelope`. An envelope that isn't the
    # budget's is none, and neither is anything but a plain id.
    def opened_from
      return @opened_from if defined?(@opened_from)

      @opened_from = Current.budget.envelopes.find_by(id: params[:envelope].to_s)
    end

    # A Reallocation goes back to the page for the month it's dated in, since that's where it's listed.
    def month_of(reallocation)
      Budget::Month.new(Current.budget, reallocation.date)
    end

    # Where a saved or deleted Reallocation goes back to.
    def return_path_for(reallocation)
      return_path(month_of(reallocation), envelope: envelope_page_for(reallocation))
    end

    # Where Cancel goes back to: for a Reallocation that's saved, where it is in the database, even when a change of
    # envelope was refused, and for a new one the page the form was opened from.
    def cancel_path(reallocation)
      if reallocation.new_record?
        return_path(@month, envelope: opened_from)
      else
        return_path(@month, envelope: envelope_page_for(reallocation))
      end
    end

    # The envelope page to go back to: the one the form was opened from, if the Reallocation is still in or out of it,
    # and otherwise its From envelope's. Judged by what's in the database, since a refused change isn't saved.
    def envelope_page_for(reallocation)
      envelope_ids = reallocation.envelope_ids_in_database
      if opened_from && envelope_ids.include?(opened_from.id)
        opened_from
      else
        Current.budget.envelopes.find_by(id: envelope_ids.first)
      end
    end

    def permitted_reallocation
      @permitted_reallocation ||= params.expect(reallocation: [ :from_envelope_id, :to_envelope_id, :description, :date, :amount, :notes ])
    end

    # The form's fields, with each envelope in `envelopes` set only from the budget's own envelopes, never from the id that
    # was sent: another budget's envelope, or one that doesn't exist, is no envelope, which the Reallocation refuses. One
    # that isn't in `envelopes`, or that the request doesn't name, is left as it is, so To can't be changed. `envelopes`
    # maps each id that comes in, such as `from_envelope_id`, to the association it sets on this kind of Reallocation.
    def reallocation_params(envelopes:)
      permitted = permitted_reallocation

      envelopes.reduce(permitted.except(:from_envelope_id, :to_envelope_id)) do |attributes, (id_param, association)|
        permitted.key?(id_param) ? attributes.merge(association => Current.budget.envelopes.find_by(id: permitted[id_param])) : attributes
      end
    end
end
