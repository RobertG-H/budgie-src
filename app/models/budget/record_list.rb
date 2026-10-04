# Every Deposit, Spend, Refund and Reallocation of a budget in one list, newest first, for a range of dates: the Records page. It's
# made from the params the page is given, `filter`, which it reads the way a page does and never trusts: what it doesn't understand
# is dropped, so `to_params` is always something it understood and nothing a person sent.
#
# - `date_from` and `date_to` are a DateRangeFilter, and apply to a record's own `date` (a Deposit is found by its date, not by the
#   month it counts toward). Both blank is the current month.
# - `kind` is `deposit`, `spend`, `refund` or `reallocation` (both tables); blank is every kind.
# - `envelope` is the id of one of the budget's envelopes; blank, or one that isn't the budget's, is all of them. An envelope leaves
#   out Deposits, which belong to none, and a Reallocation is found by either of its envelopes.
#
# The five tables are one ordered list through a UNION ALL of `(source, id, date, created_at, amount)`, which `keys` pages like a
# relation, so it goes through Paginated unchanged. The order is the date, when it was made and the id, newest first, and the table
# last, so it's total. `records` then loads each table's rows with their envelopes, which come from the budget's envelopes, loaded once, so
# the number of queries is fixed: the keys, one for each table on the page, the totals and the envelopes, however many records.
# Everything is found through the budget, so another budget's records never appear.
class Budget::RecordList
  # The kinds the page filters by. A Reallocation is two tables, which `SOURCES` tells apart: an id alone doesn't say which.
  KINDS = %w[ deposit spend refund reallocation ].freeze

  # The tables the list reads, by the name a key gives its table, and the kind each is filtered as.
  SOURCES = {
    "deposit" => "deposit", "spend" => "spend", "refund" => "refund",
    "envelope_reallocation" => "reallocation", "ready_to_assign_reallocation" => "reallocation"
  }.freeze

  # What came in and what went out over the whole range, not only the page: Deposits and Refunds, and Spends. Reallocations aren't
  # counted, since they only change which envelope money is in.
  Totals = Data.define(:money_in, :money_out)

  attr_reader :budget, :date_range, :kind, :envelope

  # `filter` is what the page was given: ActionController::Parameters, a Hash, or anything at all.
  def self.parse(budget, filter)
    values = filter.respond_to?(:to_unsafe_h) ? filter.to_unsafe_h : (filter.is_a?(Hash) ? filter : {})
    values = values.with_indifferent_access

    new(budget, date_range: DateRangeFilter.new(from: values[:date_from], to: values[:date_to]),
      kind: values[:kind], envelope_id: values[:envelope])
  end

  def initialize(budget, date_range:, kind: nil, envelope_id: nil)
    @budget = budget
    @date_range = date_range
    @kind = kind.presence_in(KINDS) if kind.is_a?(String)
    @envelope = envelopes.find { |candidate| candidate.id.to_s == envelope_id } if envelope_id.is_a?(String) && envelope_id.match?(/\A\d+\z/)
  end

  # What was understood, as the params that spell it, for a link or a hidden field.
  def to_params
    date_range.to_params.merge(kind: kind, envelope: envelope&.id&.to_s).compact
  end

  # Every envelope of the budget, alphabetically, archived ones too, which is what the Envelope picker lists and what each record's
  # envelope is found from.
  def envelopes
    @envelopes ||= budget.envelopes.alphabetical.to_a
  end

  # Where each record of the list is, in the order they're shown, to be paged: a key is the `source` table it's in and its `id`.
  # `records` loads what they name.
  def keys
    Keys.new(union_sql)
  end

  # The records the keys name, in the order of the keys, each with its envelope or envelopes loaded.
  def records(keys)
    found = keys.group_by(&:source).to_h do |source, source_keys|
      [ source, relation_for(source).where(id: source_keys.map(&:id)).index_by(&:id) ]
    end
    preload_envelopes(found)

    keys.map { |key| found.fetch(key.source).fetch(key.id) }
  end

  # Money in and money out of the whole range, or nil when the Kind is Reallocation, which has none.
  def totals
    return if kind == "reallocation"

    sql = union_sql
    return Totals.new(money_in: BigDecimal(0), money_out: BigDecimal(0)) unless sql

    money_in, money_out = connection.select_rows(<<~SQL.squish).first
      SELECT COALESCE(SUM(amount) FILTER (WHERE source IN ('deposit', 'refund')), 0),
             COALESCE(SUM(amount) FILTER (WHERE source = 'spend'), 0)
      FROM (#{sql}) AS records
    SQL
    Totals.new(money_in: BigDecimal(money_in.to_s), money_out: BigDecimal(money_out.to_s))
  end

  # A key: the table a record is in, and which record it is.
  Key = Data.define(:source, :id)

  # The keys of a union, with the little of a relation that Paginated asks of a scope: `limit`, `offset` and `to_a`, and `count`. They're
  # in the order they're shown. It's built from SQL the list wrote from the budget's own relations, never from anything a person sent;
  # the only numbers it adds are integers.
  class Keys
    def initialize(sql, limit: nil, offset: nil)
      @sql = sql
      @limit = limit
      @offset = offset
    end

    def limit(count)
      self.class.new(@sql, limit: Integer(count), offset: @offset)
    end

    def offset(count)
      self.class.new(@sql, limit: @limit, offset: Integer(count))
    end

    def to_a
      return [] unless @sql

      rows = ApplicationRecord.connection.select_rows(<<~SQL.squish)
        SELECT source, id FROM (#{@sql}) AS records
        ORDER BY date DESC, created_at DESC, id DESC, source ASC
        #{"LIMIT #{@limit}" if @limit} #{"OFFSET #{@offset}" if @offset}
      SQL
      rows.map { |source, id| Key.new(source: source, id: Integer(id)) }
    end

    def count
      @sql ? Integer(ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM (#{@sql}) AS records")) : 0
    end
  end

  private
    def connection
      ApplicationRecord.connection
    end

    # The SQL of every table the list reads, joined, or nil when none of them can hold a record the filters allow.
    def union_sql
      sources.map { |source| source_sql(source) }.join(" UNION ALL ").presence
    end

    # The tables the filters leave: the Kind's, and not Deposits when there's an envelope, which they don't belong to.
    def sources
      SOURCES.select { |source, source_kind| (kind.nil? || kind == source_kind) && !(envelope && source == "deposit") }.keys
    end

    # The rows of one table in the range, as the columns every table of the union shares.
    def source_sql(source)
      records = filtered(source)
      table = records.klass.quoted_table_name

      records.where(date: date_range.range)
        .select(Arel.sql("#{records.connection.quote(source)} AS source"), *%w[ id date created_at amount ].map { |column| Arel.sql("#{table}.#{column}") })
        .to_sql
    end

    # One table's records of the budget, in the envelope when there is one.
    def filtered(source)
      records = relation_for(source)
      return records unless envelope

      case source
      when "envelope_reallocation" then records.where(from_envelope_id: envelope.id).or(records.where(to_envelope_id: envelope.id))
      else records.where(envelope_id: envelope.id)
      end
    end

    # A table's records of the budget, by the name a key gives the table. Loading what a key names goes through the budget too, so a key
    # can only ever find the budget's own.
    def relation_for(source)
      case source
      when "deposit" then budget.deposits
      when "spend" then budget.spends
      when "refund" then budget.refunds
      when "envelope_reallocation" then budget.envelope_reallocations
      when "ready_to_assign_reallocation" then budget.ready_to_assign_reallocations
      end
    end

    # Each record's envelope or envelopes, from the budget's own, so there's no query for them.
    def preload_envelopes(found)
      found.each do |source, records|
        associations = source == "envelope_reallocation" ? %i[ from_envelope to_envelope ] : (:envelope unless source == "deposit")
        next unless associations

        ActiveRecord::Associations::Preloader.new(records: records.values, associations: associations, available_records: envelopes).call
      end
    end
end
