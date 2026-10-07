# What the controllers that act on several bank transactions at once have in common. They're ticked on the Bank transactions page and sent as `ids`,
# found through the user's budget so another user's is a 404, and each action goes back to the same page of the same filtered list (`filter` and `page`).
#
# What can't be done changes nothing and comes back as the page itself, with the reason as its alert and the selection kept, so a person can untick
# the row that stopped it and go on, and not as a redirect that would lose what they ticked.
module BulkBankTransactions
  extend ActiveSupport::Concern
  include BankTransactionsPage

  included do
    before_action :set_list
    helper_method :selected_ids
  end

  private
    def set_list
      @list = Budget::BankTransactionList.parse(Current.budget, params[:filter])
    end

    # The ids that were ticked, as text, which is all `ids` is let be: only that one key of the form is looked at, so the rest isn't reported as unpermitted.
    def selected_ids
      @selected_ids ||= Array(params.slice(:ids).permit(ids: [])[:ids]).compact_blank.uniq
    end

    # What was chosen, found through the budget: a 404 for any that isn't its own, and nothing is judged until it's there. At most a page's worth, which is
    # all there's ever a checkbox for.
    def selection
      @selection ||= Budget::BankTransaction::Selection.new(Current.budget, selected_ids)
    end

    def return_path
      bank_transactions_path(filter: @list.to_params, page: page_param)
    end

    # Nothing is chosen, or too many are.
    def selection_refusal
      if selected_ids.empty? then "Choose at least one bank transaction."
      elsif selected_ids.size > Paginated::PER_PAGE then "Choose at most #{Paginated::PER_PAGE} bank transactions at a time."
      end
    end

    # Yields the selection to be done something to, and goes back to the list with what the block returns to say when it worked, or refuses when it
    # returns nothing, for the reason the selection gives.
    def act_on_selection
      message = selection_refusal
      return refuse(message) if message

      notice = yield selection
      notice ? redirect_to(return_path, status: :see_other, notice: notice) : refuse(selection.refusal)
    end

    # The same page, as it is, with the reason and what was ticked.
    def refuse(message)
      load_bank_transactions_page(@list)
      @selected = selected_ids.map(&:to_i).to_set
      @chosen_envelope_id = params[:envelope_id]
      flash.now[:alert] = message

      render "bank_transactions/index", status: :unprocessable_content
    end
end
