# Where a form goes once it's saved, deleted or cancelled: back to the page it was opened from. That page is named
# by the form's `from` param, which can only be one of PAGES, never a URL, so it can't be made to redirect
# somewhere else. Which month the page shows depends on the form: an envelope's is the month it was opened from,
# a Deposit's is the month it counts toward, and a Spend's, a Refund's or a Reallocation's is the month of its date. See application/_origin_fields.
# A bank transaction's forms are opened from the Bank transactions page or from its Account's page, which don't have a month, and without
# one they go back to its Account.
#
# The Records page (`records`) lists records from every month and kind, and the Bank transactions page (`bank_transactions`) every bank
# transaction in any state, so a form opened from one of their rows carries the page's filter (the date range, Kind and envelope; or the
# state, Account and date range) and the page of the list it was on, and goes back to the same filtered page. The filter is never passed
# through: it's rebuilt by that page's own parser (Budget::RecordList.parse, Budget::BankTransactionList.parse), which keeps only what it
# understands, so the path that comes out is one it made and not anything that was sent. A bank transaction's forms are also opened from its
# Account's page (`account`), which has no filters.
#
# The home page is the month view of the current month at /, as well as at /months/YYYY-MM, and they're two pages to
# Turbo, which only refreshes a page in place when it's sent back to the address it's on. So `home` is a page of its
# own: it goes back to / for the current month, and for any other month, which / no longer shows, to that month.
module ReturnsToOrigin
  extend ActiveSupport::Concern

  PAGES = %w[ home month deposits envelope account records bank_transactions ].freeze

  included do
    helper_method :origin, :return_path, :origin_filter, :origin_page, :origin_params
  end

  private
    def origin
      params[:from].presence_in(PAGES)
    end

    # The filter of the Records page or the Bank transactions page, as that page reads it, as the params that spell it, when the form was
    # opened from one of them.
    def origin_filter
      case origin
      when "records" then Budget::RecordList.parse(Current.budget, params[:filter]).to_params
      when "bank_transactions" then origin_bank_transaction_list.to_params
      end
    end

    # The Bank transactions page's list as the form was opened from it, read once however many times it's asked for, since reading it loads the
    # Account that was chosen.
    def origin_bank_transaction_list
      @origin_bank_transaction_list ||= Budget::BankTransactionList.parse(Current.budget, params[:filter])
    end

    # The page of the list the form was opened from, for the pages that have one: a number past the first, and nothing for the first.
    def origin_page
      return unless origin.in?(%w[ records bank_transactions ])

      page = Paginated.page_number(params[:page])
      page unless page == 1
    end

    # What a button of its own, such as Delete, sends so that it can go back to the page the record was opened from.
    def origin_params(month)
      { from: origin, month: month.to_param, filter: origin_filter, page: origin_page }.compact
    end

    # The path of the page the form was opened from, showing `month`. The envelope's page needs the `envelope`;
    # without one, as for a Deposit, or an envelope that has just been deleted, it's the month view instead. A bank transaction's
    # forms have no month, and the Account page, which is where they go without a `from`, needs its `account`.
    def return_path(month = nil, envelope: nil, account: nil)
      month ||= Budget::Month.new(Current.budget, Date.current)

      case origin
      when "home" then month.current? ? root_path : month_path(month)
      when "deposits" then month_deposits_path(month)
      when "envelope" then envelope ? month_envelope_path(month, envelope) : month_path(month)
      when "records" then records_path(filter: origin_filter, page: origin_page)
      when "bank_transactions" then bank_transactions_path(filter: origin_filter, page: origin_page)
      when "account" then account ? account_path(account) : accounts_path
      else account ? account_path(account) : month_path(month)
      end
    end
end
