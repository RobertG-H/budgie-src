# Turns bank transactions into the Deposits, Spends and Refunds they were, which is filing (ADR 0009). It's one operation:
# it takes bank transactions, each with the records it's filed as, and files them all or none. A person calls it from the
# filing form with one bank transaction and one record or several, and Filing rules and a Guess will call the same operation.
#
#   filing = Budget::Filing.new(budget)
#   filing.file([ Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: [ draft ]) ])
#
# Each draft is a record as it's asked for, which is what a form sends. Money in is filed as Deposits and Refunds, money out as
# Spends and never as a Reallocation, and the records have to add up to the bank transaction's amount exactly: there's no partly
# filed state. When anything is wrong nothing at all is created, and what's wrong is on the entry (for the bank transaction) or on
# its draft (for a record), in the words a typed-in record would use.
#
# It makes the same number of queries however many bank transactions and records there are: the budget's envelopes are loaded
# once, every record is validated in memory, the bank transactions are locked in one query, every record and link of a kind is
# inserted in one statement, and so is the note of which Filing rule filed them, which is none when a person did.
class Budget::Filing
  KINDS_BY_SIGN = { in: %w[ deposit refund ], out: %w[ spend ] }.freeze
  # Far more than a bank transaction is ever split into, so that one that's been sent a lot of them is refused.
  MAX_RECORDS = 50

  attr_reader :entries

  def initialize(budget)
    @budget = budget
  end

  # Files every entry, and is true when that worked. It's false when anything is refused, and then nothing was filed.
  def file(entries)
    @entries = entries
    return true if entries.empty?

    # Asked for afresh, not from the budget's loaded association, so an envelope archived since is archived here.
    envelopes = Budget::Envelope.where(budget_id: @budget.id).index_by(&:id)
    entries.each { |entry| check(entry, envelopes) }
    return false if entries.any?(&:refused?)

    Budget::BankTransaction.transaction do
      check_unfiled(entries)
      raise ActiveRecord::Rollback if entries.any?(&:refused?)

      insert(entries)
    end

    entries.none?(&:refused?)
  end

  def filed?
    entries.present? ? entries.none?(&:refused?) : true
  end

  private
    # Everything that can be said without locking anything: what's wrong with each record, whether the kinds fit the money, and
    # whether the records add up to the amount.
    def check(entry, envelopes)
      entry.errors.clear
      return entry.errors.add(:base, "File it as at least one record.") if entry.drafts.empty?
      return entry.errors.add(:base, "A bank transaction can be filed as at most #{MAX_RECORDS} records.") if entry.drafts.size > MAX_RECORDS

      entry.drafts.each { |draft| check_draft(draft, entry.bank_transaction, envelopes) }
      check_sum(entry) unless entry.refused?
    end

    def check_draft(draft, bank_transaction, envelopes)
      draft.errors.clear
      draft.record = nil
      money_in = bank_transaction.amount.positive?

      unless KINDS_BY_SIGN.fetch(money_in ? :in : :out).include?(draft.kind)
        return draft.errors.add(:kind, money_in ? "must be Deposit or Refund, since the money came in" : "must be Spend, since the money went out")
      end

      record = draft.build_record(@budget, envelopes)
      draft.copy_errors_from(record) unless record.valid?
      draft.record = record
    end

    def check_sum(entry)
      total = entry.drafts.sum { |draft| draft.record.amount }
      difference = total - entry.bank_transaction.amount.abs
      return if difference.zero?

      entry.errors.add(:base, "The records add up to #{money(total)}, which is #{money(difference.abs)} #{difference.negative? ? "less" : "more"} " \
        "than the bank transaction's #{money(entry.bank_transaction.amount.abs)}.")
    end

    # What can only be said once the bank transactions are locked: that they're the budget's, and unfiled. A double submit finds
    # the first one's records, so it files nothing.
    def check_unfiled(entries)
      ids = entries.map { |entry| entry.bank_transaction.id }
      locked = Budget::BankTransaction.where(id: @budget.bank_transactions.where(id: ids).select(:id)).lock.index_by(&:id)
      filed = Budget::BankTransaction.links_by_record.values.flat_map { |link| link.where(bank_transaction_id: ids).distinct.pluck(:bank_transaction_id) }.to_set

      entries.each do |entry|
        current = locked[entry.bank_transaction.id]

        if current.nil?
          entry.errors.add(:base, "This bank transaction isn't in this budget.")
        elsif current.ignored?
          entry.errors.add(:base, Budget::BankTransaction::FILING_REFUSALS.fetch(:ignored))
        elsif filed.include?(current.id)
          entry.errors.add(:base, Budget::BankTransaction::FILING_REFUSALS.fetch(:filed))
        end
      end
    end

    # Every record of a kind in one statement, and then every link of that kind, which needs the ids the records were given. Then which
    # rule filed each bank transaction, which overwrites one that went stale when its last record was deleted by hand.
    def insert(entries)
      pairs = entries.flat_map { |entry| entry.drafts.map { |draft| [ entry.bank_transaction, draft.record ] } }

      pairs.group_by { |_, record| record.class }.each do |record_class, kind_pairs|
        ids = record_class.insert_all!(kind_pairs.map { |_, record| record.attributes.except("id", "created_at", "updated_at") }, returning: %w[ id ]).rows.flatten
        column = :"#{record_class.model_name.element}_id"

        Budget::BankTransaction.links_by_record.fetch(record_class).insert_all!(kind_pairs.zip(ids).map { |(bank_transaction, _), id| { bank_transaction_id: bank_transaction.id, column => id } })
      end

      Budget::BankTransaction.record_filing_rules(entries.to_h { |entry| [ entry.bank_transaction.id, entry.filing_rule&.id ] })
    end

    def money(amount)
      ActiveSupport::NumberHelper.number_to_currency(amount, unit: @budget.currency_unit)
    end
end
