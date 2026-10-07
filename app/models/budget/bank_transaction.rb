# The bank's record of money moving in or out of an Account, before Budgie has filed it as Deposits, Spends and Refunds, or
# ignored it. Its amount is signed: positive is money in and negative is money out, never 0 (ADR 0009).
#
# It belongs to its budget through its Account, as a Spend does through its envelope, so it has no budget of its own. It's
# read-only to the person: bank transactions come from an Import and go with it, or with their Account's budget, or from a sync
# of the Account's connection (ADR 0016), which has no Import and tells its rows apart by the provider's `external_id` for each.
#
# What says which row it is in its Account (ADR 0010) is its content key and occurrence, which are written once, when the row
# is made, and never again, because they record how it first looked. The description is as the bank gave it, so it can be
# updated in place later, and `normalized_description` is kept by the database to follow it, for a Filing rule or a Guess to
# read. For one a sync brought in, the row is told apart by its `external_id` (the Splitwise expense's id), and the content key and
# occurrence are only there to keep the Account's rows distinct: an edit in Splitwise updates the date, amount and description in place and
# never the key, the occurrence or any record that was filed from it. One that went from the provider has `removed_at` set, and is never deleted.
#
# It's unfiled, filed or ignored, which is derived and never stored: ignored if `ignored_at` is set, filed if it has at least one
# link, and otherwise unfiled. It's never both ignored and filed, and never partly filed: Filing (Budget::Filing) makes every
# record and link at once, and they add up to its amount, though a record edited afterwards may stop it (the flag, see
# `adds_up?`, which blocks nothing, ADR 0009). One that's removed and was neither filed nor ignored is none of the three, since it leaves
# the Unfiled state and can't be filed (`state` says `removed`). It changes only through ignoring and un-ignoring, filing and un-filing,
# Undo, a sync's update, and deletion through its Account or Budget.
class Budget::BankTransaction < ApplicationRecord
  # Raised when a bank transaction can't be ignored, un-ignored or un-filed as asked; the message says why, for the person who
  # asked.
  class Refused < StandardError; end

  # Why a bank transaction can't be filed, by the state that stops it.
  FILING_REFUSALS = {
    filed: "This bank transaction is already filed.",
    ignored: "This bank transaction is ignored. Un-ignore it first.",
    removed: "This bank transaction was deleted in Splitwise, so it can't be filed."
  }.freeze

  belongs_to :account
  # The Import it came from, which a row a sync brought in has none of: it has its `external_id` instead.
  belongs_to :import, optional: true
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
  # A blank id is no id, so a row with only that is refused for having neither it nor an Import, in the model as the database's check says.
  normalizes :external_id, with: ->(external_id) { external_id.strip.presence }

  before_validation :set_content_key_and_occurrence, on: :create

  validates :description, presence: true
  validates :date, presence: true
  validates :amount, money: true
  validates :external_id, uniqueness: { scope: :account_id, message: "is already in this Account" }, allow_nil: true
  validate :amount_is_not_zero
  validate :comes_from_an_import_or_a_connection
  validate :not_ignored_and_filed, if: :ignored_at_changed?

  scope :newest_first, -> { order(date: :desc, id: :desc) }
  # Neither ignored, filed as anything nor removed (gone from the provider it was synced from, so there's nothing to file). Left joins, so a bank
  # transaction with several links is still found once.
  scope :unfiled, -> { where(ignored_at: nil, removed_at: nil).where.missing(:deposit_links, :spend_links, :refund_links) }

  # Filed as at least one record, and not ignored, whichever kind of record: found by what its links are, so one with several is
  # still found once. With `unfiled` and `ignored`, every bank transaction is in exactly one of the three, except one that's removed
  # and was neither filed nor ignored, which is in none, and nothing is both ignored and filed, which the model refuses.
  scope :filed, -> {
    where(ignored_at: nil).where(id: Budget::DepositLink.select(:bank_transaction_id))
      .or(where(ignored_at: nil).where(id: Budget::SpendLink.select(:bank_transaction_id)))
      .or(where(ignored_at: nil).where(id: Budget::RefundLink.select(:bank_transaction_id)))
  }
  scope :ignored, -> { where.not(ignored_at: nil) }

  # Ignored, or filed as at least one record: what isn't unfiled. Left joins, so one with several links is still counted once, with `distinct`.
  scope :filed_or_ignored, -> {
    left_joins(:deposit_links, :spend_links, :refund_links)
      .where("budget_bank_transactions.ignored_at IS NOT NULL OR budget_deposit_links.id IS NOT NULL OR budget_spend_links.id IS NOT NULL OR budget_refund_links.id IS NOT NULL")
      .distinct
  }

  # Which way the money went: in is positive and out is negative.
  scope :money_in, -> { where("budget_bank_transactions.amount > 0") }
  scope :money_out, -> { where("budget_bank_transactions.amount < 0") }

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
  def self.note_filing_rules(rule_ids_by_id, **attributes)
    return if rule_ids_by_id.empty?

    # Cast, since a CASE of nothing but nulls is text to PostgreSQL, which is what it is when a person did them all.
    rule_ids = rule_ids_by_id.reduce(Arel::Nodes::Case.new(arel_table[:id])) { |node, (id, rule_id)| node.when(id).then(rule_id) }
    where(id: rule_ids_by_id.keys).update_all(attributes.merge(filing_rule_id: Arel::Nodes::NamedFunction.new("CAST", [ rule_ids.as("bigint") ]), updated_at: Time.current))
  end

  # The four columns a sync ever writes on a bank transaction it already has, and their types, which a CASE of nothing but nulls needs said.
  SYNCED_COLUMNS = { date: "date", description: "varchar", amount: "numeric", removed_at: "timestamp" }.freeze

  # What a sync changed, in one statement however many there are: `changes` is `{ id => { date:, description:, amount:, removed_at: } }`, every column of
  # SYNCED_COLUMNS for each. Never the content key or the occurrence, which record how a row first looked (ADR 0010), and never a record that was filed from it.
  def self.update_from_sync(changes)
    return if changes.empty?

    assignments = SYNCED_COLUMNS.to_h do |column, type|
      cases = changes.reduce(Arel::Nodes::Case.new(arel_table[:id])) { |node, (id, values)| node.when(id).then(values.fetch(column)) }
      [ column, Arel::Nodes::NamedFunction.new("CAST", [ cases.as(type) ]) ]
    end

    where(id: changes.keys).update_all(assignments.merge(updated_at: Time.current))
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

  # What a bank puts between a merchant and a reference to it, which are spaces to a Filing rule: "Pioneer #41051", "Presto Fare/Smzxv6Sckh".
  NOISE_SEPARATORS = %r{[#/*\\_,]}
  # The last word after a "/", with no other "/" or space in it: a reference to this one bank transaction ("Presto Fare/Shwqfxpddf").
  TRAILING_REFERENCE = %r{/[^\s/]+\z}
  # Punctuation at either end of a word, which is no part of it ("(toronto)", "costco.").
  WORD_EDGES = /\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/
  # A word with this many digits is a number: an id, a store number or a reference ("41051"), where one or two are part of a name ("7-eleven", "3m").
  NUMBER_DIGITS = 3

  # A description, or a rule's text, as a Filing rule compares them, which is without what changes from one bank transaction to the next
  # (#117): "Loblaws #1029" and "Loblaws #1031" are both "loblaws", and "Internet Banking E-TRANSFER 106121984683 James Graham-Hu" is
  # "internet banking e-transfer james graham-hu". Squished and case folded as `normalize_description` does, then a single last word after
  # a "/" is dropped, `# / * \ _ ,` are spaces, punctuation at a word's ends is trimmed, and a word is dropped when it has no letter, has
  # three or more digits, or is one character. What's left keeps its hyphens, apostrophes, ampersands, at signs and dots inside a word. It
  # changes nothing when it's applied again, which the text of a rule needs, as does a form's default text fitting its own bank transaction.
  #
  # It's a function of its own, and `normalize_description` is not changed, since the content key is made from that one and a key is never
  # recomputed (ADR 0010).
  def self.normalize_for_matching(text)
    words = normalize_description(text).sub(TRAILING_REFERENCE, "").gsub(NOISE_SEPARATORS, " ").split.filter_map do |word|
      word = word.gsub(WORD_EDGES, "")
      word unless word.length < 2 || !word.match?(/\p{L}/) || word.scan(/\p{N}/).size >= NUMBER_DIGITS
    end

    words.join(" ")
  end

  # The description as a Filing rule reads it (`normalize_for_matching`), here in Ruby as the rule's own text is, so the two can't disagree
  # over an unusual space or case fold the way the database's `normalized_description` could, which is only SQL's idea of the same thing.
  # It's kept for as long as the description is the same, since an Import matches every row against every rule.
  def description_for_matching
    @description_for_matching = nil unless @description_matched == description
    @description_matched = description
    @description_for_matching ||= self.class.normalize_for_matching(description)
  end

  def ignored?
    ignored_at.present?
  end

  def filed?
    [ deposit_links, spend_links, refund_links ].any?(&:any?)
  end

  def unfiled?
    state == :unfiled
  end

  # It went from the provider it was synced from, such as a Splitwise expense that was deleted, or that no longer has a share for the person.
  # It's kept, since what was filed from it stays, and a sync that finds it again clears this.
  def removed?
    removed_at.present?
  end

  # The Filing rule that filed or ignored it, which is nothing for one that's unfiled, or that a person filed or ignored.
  def filed_by_rule
    filing_rule if filed? || ignored?
  end

  def state
    if ignored? then :ignored
    elsif filed? then :filed
    elsif removed? then :removed
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

  # Whether its records add up to its amount, which they do when they're made. Editing one so they don't, or a sync changing the amount, blocks
  # nothing, and is shown as a flag (ADR 0009). A bank transaction that isn't filed has nothing to add up, and isn't flagged. They don't add up either
  # when they no longer suit its sign, though the sizes are the same, since a Refund can't stand for money out.
  def adds_up?
    !filed? || (filed_total == amount.abs && records_suit_the_sign?)
  end

  # Whether what it was filed as is the kind its money calls for: money out is Spends, and money in Deposits and Refunds (Budget::Filing). They are when it's
  # filed, and stop being if a sync turns money in into money out, or the other way. One that isn't filed has none to suit.
  def records_suit_the_sign?
    records_unsuited_to_the_sign.empty?
  end

  # The records that no longer suit its sign: Spends when it's money in, and Deposits and Refunds when it's money out.
  def records_unsuited_to_the_sign
    filed_records.select { |record| record.is_a?(Budget::Spend) == amount.positive? }
  end

  # The next unfiled bank transaction in `scope`, which is what working through a list one at a time goes to: the first unfiled one older than this
  # one, in the list's order (`date`, then `id`, newest first), and when none is older, the newest unfiled one left, so working from the middle of
  # a list still finishes it. Nothing when no other is unfiled. It's judged when it's asked, so one filed since, such as this one just now, is never
  # offered, and it's one query, wrap included: the older ones are ordered first.
  def next_unfiled(scope:)
    older_first = Arel.sql(self.class.sanitize_sql_array([ "(budget_bank_transactions.date, budget_bank_transactions.id) < (?, ?) DESC", date, id ]))

    scope.unfiled.where.not(id: id).order(older_first).newest_first.first
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

    # It says where it came from: the Import that read it from a file, or the provider's id for it, which the database checks too.
    def comes_from_an_import_or_a_connection
      errors.add(:base, "Bank transaction needs an Import or an external id") if import_id.nil? && import.nil? && external_id.nil?
    end

    def amount_is_not_zero
      errors.add(:amount, "must be other than 0") if amount&.zero? && !errors.include?(:amount)
    end
end
