# Several of a budget's bank transactions that a person has chosen on the Bank transactions page, to file, ignore, un-file, un-ignore or mark
# reviewed in one go. They're found through the budget, so another budget's is no bank transaction (`ActiveRecord::RecordNotFound`).
#
#   selection = Budget::BankTransaction::Selection.new(budget, ids)
#   selection.file_to(envelope_id) # => true, or false with `refusal` saying why
#
# Filing, ignoring, un-filing and un-ignoring are all or none, as filing is: the rows are locked in one query and each is judged once the
# locks are held, so one filed, ignored or un-filed in another tab since the page was drawn refuses the lot, and `refusal` names the first
# row (in the page's order) and says why, in the words one at a time uses. Mark reviewed is lenient (ADR 0017): it marks the ones that are
# still to review and says how many, and one that isn't any more doesn't refuse the rest.
#
# Each makes the same number of queries for 5 rows as for 50.
class Budget::BankTransaction::Selection
  attr_reader :bank_transactions, :refusal

  def initialize(budget, ids)
    @budget = budget
    @bank_transactions = budget.bank_transactions.find(Array(ids).map(&:to_s).uniq).sort_by { |row| [ row.date, row.id ] }.reverse
  end

  def count
    @bank_transactions.size
  end

  # Files each as one record of its whole amount to the envelope (`envelope_id` is looked up in the budget's own, so another's is refused): a Spend
  # for money out and a Refund for money in, with the bank's description and date and no notes, through the operation a person's filing uses.
  def file_to(envelope_id)
    entries = @bank_transactions.map do |bank_transaction|
      kind = bank_transaction.amount.positive? ? "refund" : "spend"
      Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: [ Budget::Filing::Draft.for(bank_transaction, kind: kind, envelope_id: envelope_id) ])
    end
    filing = Budget::Filing.new(@budget)

    filing.file(entries).tap { @refusal = filing.refusal }
  end

  # Ignoring is what a person chose, so it isn't to review.
  def ignore
    change("ignored", refusing: ->(row, filed) { ignoring_refusal(row, filed) }) do |ids|
      Budget::BankTransaction.where(id: ids).update_all(ignored_at: Time.current, filing_rule_id: nil, updated_at: Time.current)
    end
  end

  def unignore
    change("un-ignored", refusing: ->(row, _filed) { "This bank transaction isn't ignored." unless row.ignored? }) do |ids|
      Budget::BankTransaction.where(id: ids).update_all(ignored_at: nil, filing_rule_id: nil, updated_at: Time.current)
    end
  end

  # Deletes the records they were filed as, which makes each unfiled again.
  def unfile
    change("un-filed", refusing: ->(row, filed) { "This bank transaction isn't filed." unless filed.include?(row.id) }) do |ids|
      Budget::BankTransaction.delete_filed_records(Budget::BankTransaction.where(id: ids))
      Budget::BankTransaction.where(id: ids).update_all(filing_rule_id: nil, updated_at: Time.current)
    end
  end

  # Marks reviewed the ones that are still to review, and says how many that was.
  def mark_reviewed
    Budget::BankTransaction.mark_reviewed(Budget::BankTransaction.where(id: @bank_transactions.map(&:id)))
  end

  private
    def ignoring_refusal(row, filed)
      if filed.include?(row.id) then "This bank transaction is filed. Un-file it before ignoring it."
      elsif row.ignored? then "This bank transaction is already ignored."
      end
    end

    # Locks the rows, which is judged against: `refusing` gives a reason for a row it can't be done to, or nothing, and when any has one nothing
    # is changed. Otherwise the block changes them all.
    def change(verb, refusing:)
      ids = @bank_transactions.map(&:id)
      @refusal = nil

      Budget::BankTransaction.transaction do
        locked = Budget::BankTransaction.where(id: ids).lock.index_by(&:id)
        filed = Budget::BankTransaction.links_by_record.values.flat_map { |link| link.where(bank_transaction_id: ids).distinct.pluck(:bank_transaction_id) }.to_set

        @bank_transactions.each do |row|
          current = locked[row.id]
          reason = current ? refusing.call(current, filed) : "This bank transaction is gone, such as when its Import was undone."
          next unless reason

          @refusal = "Nothing was #{verb}. #{row.description}: #{reason}"
          break
        end

        yield ids if @refusal.nil?
      end

      @refusal.nil?
    end
end
