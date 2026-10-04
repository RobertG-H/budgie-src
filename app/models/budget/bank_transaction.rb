# The bank's record of money moving in or out of an Account, before Budgie has filed it as Deposits, Spends and Refunds, or
# ignored it. Its amount is signed: positive is money in and negative is money out, never 0 (ADR 0009).
#
# It belongs to its budget through its Account, as a Spend does through its envelope, so it has no budget of its own. It's
# read-only to the person: bank transactions come from an Import and go with it, or with their Account's budget.
#
# What says which row it is in its Account (ADR 0010) is its content key and occurrence, which are written once, when the row
# is made, and never again, because they record how it first looked. The description is as the bank gave it, so it can be
# updated in place later, and `normalized_description` is kept by the database to follow it, for a Filing rule or a Guess to
# read.
#
# It's unfiled, filed or ignored, which is derived and never stored: ignored if `ignored_at` is set, filed if it has at least one
# link, and otherwise unfiled. It's never both ignored and filed, and never partly filed: Filing (Budget::Filing) makes every
# record and link at once, and they add up to its amount, though a record edited afterwards may stop it (the flag, see
# `adds_up?`, which blocks nothing, ADR 0009). It changes only through ignoring and un-ignoring, filing and un-filing, Undo, a
# sync's update, and deletion through its Account or Budget.
class Budget::BankTransaction < ApplicationRecord
  # Raised when a bank transaction can't be ignored, un-ignored or un-filed as asked; the message says why, for the person who
  # asked.
  class Refused < StandardError; end

  # Why a bank transaction can't be filed, by the state that stops it.
  FILING_REFUSALS = { filed: "This bank transaction is already filed.", ignored: "This bank transaction is ignored. Un-ignore it first." }.freeze

  belongs_to :account
  belongs_to :import
  # The Filing rule that filed or ignored it, if one did and it's still filed or ignored: null when a person did it. It's only to
  # be read while the bank transaction is filed or ignored (see `filed_by_rule`), since deleting its last record by hand leaves
  # the value stale, until the next filing or ignoring writes it again.
  belongs_to :filing_rule, optional: true
  # What it was filed as, a link for each record. A bank transaction with links can't be deleted: the model refuses, and the
  # database's ON DELETE RESTRICT is the backstop. Un-filing, Undo and deleting the Budget delete the links with their records.
  has_many :deposit_links, class_name: "Budget::DepositLink", dependent: :restrict_with_error
  has_many :spend_links, class_name: "Budget::SpendLink", dependent: :restrict_with_error
  has_many :refund_links, class_name: "Budget::RefundLink", dependent: :restrict_with_error

  normalizes :description, with: ->(description) { description.strip }

  before_validation :set_content_key_and_occurrence, on: :create

  validates :description, presence: true
  validates :date, presence: true
  validates :amount, money: true
  validate :amount_is_not_zero
  validate :not_ignored_and_filed, if: :ignored_at_changed?

  scope :newest_first, -> { order(date: :desc, id: :desc) }
  # Neither ignored nor filed as anything. Left joins, so a bank transaction with several links is still found once.
  scope :unfiled, -> { where(ignored_at: nil).where.missing(:deposit_links, :spend_links, :refund_links) }

  # Ignored, or filed as at least one record: what isn't unfiled. Left joins, so one with several links is still counted once, with `distinct`.
  scope :filed_or_ignored, -> {
    left_joins(:deposit_links, :spend_links, :refund_links)
      .where("budget_bank_transactions.ignored_at IS NOT NULL OR budget_deposit_links.id IS NOT NULL OR budget_spend_links.id IS NOT NULL OR budget_refund_links.id IS NOT NULL")
      .distinct
  }

  # The three kinds of record a bank transaction is filed as, each with the link table that holds it: the record's class, then its
  # link's. Everything that has to treat the kinds alike, such as inserting them or deleting them, goes through this.
  def self.links_by_record
    { Budget::Deposit => Budget::DepositLink, Budget::Spend => Budget::SpendLink, Budget::Refund => Budget::RefundLink }
  end

  # The records that were filed from the bank transactions in `transactions`, and their links, deleted straight from the tables
  # and without asking whether they add up. It's what un-filing, Undo and deleting the Budget all do, in the order that the
  # foreign keys allow: a link, then the record it holds.
  def self.delete_filed_records(transactions)
    ids = transactions.select(:id)

    links_by_record.each do |record_class, link_class|
      links = link_class.where(bank_transaction_id: ids)
      record_ids = links.pluck(:"#{record_class.model_name.element}_id")
      links.delete_all
      record_class.where(id: record_ids).delete_all
    end
  end

  # Notes which Filing rule filed or ignored each bank transaction, which is the value for its id in `rule_ids_by_id`, or none (nil) for
  # one that a person did. It's one statement however many there are, and `attributes` are set on them all, such as when they were
  # ignored.
  def self.record_filing_rules(rule_ids_by_id, **attributes)
    return if rule_ids_by_id.empty?

    # Cast, since a CASE of nothing but nulls is text to PostgreSQL, which is what it is when a person did them all.
    rule_ids = rule_ids_by_id.reduce(Arel::Nodes::Case.new(arel_table[:id])) { |node, (id, rule_id)| node.when(id).then(rule_id) }
    where(id: rule_ids_by_id.keys).update_all(attributes.merge(filing_rule_id: Arel::Nodes::NamedFunction.new("CAST", [ rule_ids.as("bigint") ]), updated_at: Time.current))
  end

  # How many records of each kind were filed from the bank transactions in `transactions`, by the kind's plural: `{ deposits: 1,
  # spends: 2, refunds: 0 }`. What Undo says it will delete.
  def self.filed_record_counts(transactions)
    ids = transactions.select(:id)

    links_by_record.to_h { |record_class, link_class| [ record_class.model_name.route_key.to_sym, link_class.where(bank_transaction_id: ids).count ] }
  end

  # The key of a row: a digest of its Account, date, signed amount and description, with the description trimmed, its
  # whitespace collapsed and its case folded, so a row that differs in nothing a person would notice is the same row.
  def self.content_key(account_id:, date:, amount:, description:)
    Digest::SHA256.hexdigest([ account_id, date.iso8601, format("%.2f", amount), normalize_description(description) ].join("\u001F"))
  end

  def self.normalize_description(description)
    description.squish.downcase(:fold)
  end

  def ignored?
    ignored_at.present?
  end

  def filed?
    [ deposit_links, spend_links, refund_links ].any?(&:any?)
  end

  def unfiled?
    !ignored? && !filed?
  end

  # The Filing rule that filed or ignored it, which is nothing for one that's unfiled, or that a person filed or ignored.
  def filed_by_rule
    filing_rule if filed? || ignored?
  end

  def state
    if ignored? then :ignored
    elsif filed? then :filed
    else :unfiled
    end
  end

  # The records it was filed as, which are ordinary Deposits, Spends and Refunds. Preload the links and their records for a list.
  def filed_records
    deposit_links.map(&:deposit) + spend_links.map(&:spend) + refund_links.map(&:refund)
  end

  # What its records add up to, which is every one's amount, since they're all positive.
  def filed_total
    filed_records.sum(&:amount)
  end

  # Whether its records add up to its amount, which they do when they're made. Editing one so they don't blocks nothing, and is
  # shown as a flag (ADR 0009). A bank transaction that isn't filed has nothing to add up, and isn't flagged.
  def adds_up?
    !filed? || filed_total == amount.abs
  end

  # Won't be filed: sets when it was ignored, such as for a card payment between a person's own accounts. Only an unfiled bank
  # transaction can be, which is judged once it's locked, so a record filed since it was looked at stops it.
  def ignore
    with_lock do
      raise Refused, "This bank transaction is filed. Un-file it before ignoring it." if filed?
      raise Refused, "This bank transaction is already ignored." if ignored?

      update!(ignored_at: Time.current, filing_rule_id: nil)
    end
  end

  def unignore
    with_lock do
      raise Refused, "This bank transaction isn't ignored." unless ignored?

      update!(ignored_at: nil, filing_rule_id: nil)
    end
  end

  # Deletes the records it was filed as and their links, which makes it unfiled again, in one transaction.
  def unfile
    with_lock do
      raise Refused, "This bank transaction isn't filed." unless filed?

      self.class.delete_filed_records(self.class.where(id: id))
      update!(filing_rule_id: nil)
    end
  end

  private
    # A row made one at a time is the next occurrence of its key. An Import numbers all of its rows itself, in one go.
    def set_content_key_and_occurrence
      return if content_key.present? || account_id.nil? || date.nil? || amount.nil? || description.blank?

      self.content_key = self.class.content_key(account_id: account_id, date: date, amount: amount, description: description)
      self.occurrence ||= account.bank_transactions.where(content_key: content_key).maximum(:occurrence).to_i + 1
    end

    def not_ignored_and_filed
      errors.add(:base, "Bank transaction is filed, so it can't be ignored") if ignored_at.present? && filed?
    end

    def amount_is_not_zero
      errors.add(:amount, "must be other than 0") if amount&.zero? && !errors.include?(:amount)
    end
end
