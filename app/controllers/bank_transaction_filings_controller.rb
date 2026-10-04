# Filing a bank transaction as the Deposits, Spends and Refunds it was (ADR 0009), and taking that back. The form is opened from the
# Unfiled list or from the bank transaction's Account, and saving, ignoring or cancelling goes back there (ReturnsToOrigin).
class BankTransactionFilingsController < ApplicationController
  include BankTransactionScoped
  include FilingFormParams

  before_action :require_unfiled, only: %i[ new create ]

  # Starts as the bank transaction would be filed with nothing changed: its date and description, and all of its amount.
  def new
    @entry = Budget::Filing::Entry.new(bank_transaction: @bank_transaction, drafts: [ Budget::Filing::Draft.for(@bank_transaction) ])
    @offer = filing_rule_offer(sent: false)
  end

  # Files it as the records the form has, all or none, and makes a Filing rule from it if "Always file like this" was ticked, in the same
  # database transaction. What's wrong comes back on the form, with everything as it was entered.
  def create
    @entry = Budget::Filing::Entry.new(bank_transaction: @bank_transaction, drafts: draft_params)
    @offer = filing_rule_offer(records: @entry.drafts.size)

    if @offer.make? ? @offer.file(@entry) : Budget::Filing.new(Current.budget).file([ @entry ])
      redirect_to origin_path, notice: notice_with_sweep("Bank transaction filed.", @offer)
    else
      render :new, status: :unprocessable_content
    end
  end

  # Un-files it: the records it was filed as are deleted, and it's unfiled again.
  def destroy
    @bank_transaction.unfile
    redirect_to origin_path, status: :see_other, notice: "Bank transaction unfiled."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to origin_path, status: :see_other, alert: refusal.message
  end

  private
    # Only an unfiled bank transaction can be filed: one that isn't says why, where the form was opened from.
    def require_unfiled
      redirect_to origin_path, alert: Budget::BankTransaction::FILING_REFUSALS.fetch(@bank_transaction.state) unless @bank_transaction.unfiled?
    end
end
