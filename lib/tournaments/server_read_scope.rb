require_relative 'publication'

module GameRoomTournaments
  # A worker operation reuses immutable SDK query results. Nothing survives the
  # operation. Append-only table revisions invalidate affected reads at write
  # boundaries; this is not a server transaction or a long-lived state cache.
  class ServerReadScope
    KEY = :power_games_tournament_read_scope
    MAX_QUERIES = 2048
    MAX_BYTES = 33_554_432
    REVISION_QUERY = {where: {}.freeze, order: [['__id', 'desc'].freeze].freeze, limit: 1}.freeze

    def self.run(identity, &block)
      previous = Thread.current[KEY]
      return block.call if previous && previous.identity == identity
      Thread.current[KEY] = new(identity)
      begin
        block.call
      ensure
        Thread.current[KEY] = previous
      end
    end

    def self.refresh!(only: nil)
      Thread.current[KEY]&.refresh!(only: only)
    end

    def self.verify(&block)
      scope=Thread.current[KEY]
      scope ? scope.verify(&block) : block.call
    end

    attr_reader :identity

    def initialize(identity)
      @identity, @tables, @bytes, @queries = identity, {}, 0, 0
      @io_sequence=0
    end

    def select(table, arguments)
      entry = (@tables[table] ||= new_entry(table))
      key = JSON.generate(arguments)
      return entry[:queries][key][:rows] if entry[:queries].key?(key)
      head = entry[:queries][JSON.generate(REVISION_QUERY)]&.fetch(:rows)
      if head && (head.empty? || arguments[:limit] == 1 && arguments[:order] == REVISION_QUERY[:order] &&
          matching_head?(head.first, arguments.fetch(:where, {})))
        return remember(entry, key, arguments, head)
      end
      @io_sequence+=1
      rows = table.raw.select(**arguments).to_a
      remember(entry, key, arguments, rows)
    end

    # A complete bounded document read can answer narrower operation-key
    # queries in this same operation. Never infer completeness from one page
    # or apply client-side text/collation rules to arbitrary SDK filters.
    def document_rows(table, where)
      wanted = document_keys(where)
      return yield unless wanted
      entry = (@tables[table] ||= new_entry(table))
      remaining = wanted.dup
      found = []
      entry[:queries].each_value do |query|
        keys = query[:document_keys]
        next unless keys
        covered = remaining & keys
        next if covered.empty?
        found.concat(query[:rows].select { |row| covered.include?(row['operation_key']) })
        remaining -= covered
        return found.sort_by { |row| row.fetch('__id') }.freeze if remaining.empty?
      end
      revision = entry[:revision]
      rows = yield
      # A reentrant write/refresh must not publish a pre-write observation.
      return rows unless @tables[table].equal?(entry) && entry[:revision] == revision
      key = 'documents:' + JSON.generate(wanted.sort)
      remember(entry, key, {where: where}, rows)
      entry[:queries].fetch(key)[:document_keys] = wanted.freeze
      entry[:queries].fetch(key)[:rows]
    end

    private def remember(entry, key, arguments, rows)
      rows = Publication::Data.freeze_tree(Publication::Data.copy(rows,
        max_bytes: MAX_BYTES, max_nodes: 262_144, max_depth: 12))
      bytes = JSON.generate(rows).bytesize
      previous=entry[:queries][key]
      next_bytes=@bytes+bytes-(previous ? previous[:bytes] : 0)
      next_queries=@queries+(previous ? 0 : 1)
      raise Publication::Invalid, :document_read_limit if next_queries > MAX_QUERIES || next_bytes > MAX_BYTES
      @bytes=next_bytes
      @queries=next_queries
      entry[:queries][key] = {rows: rows, bytes: bytes, arguments: Publication::Data.freeze_tree(Publication::Data.copy(arguments.transform_keys(&:to_s)))}
      rows
    end

    private def document_keys(where)
      return unless where.is_a?(Hash) && where.keys == ['operation_key']
      value = where['operation_key']
      keys = value.is_a?(Hash) && value.keys == ['in'] ? value['in'] : [value]
      keys if keys.is_a?(Array) && !keys.empty? && keys.all? { |key| key.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(key) }
    end

    private def matching_head?(row, where)
      where.is_a?(Hash) && where.all? do |field, expected|
        value = row[field]
        row.key?(field) && if expected.is_a?(Hash)
          expected.keys == ['in'] && expected['in'].is_a?(Array) && expected['in'].include?(value)
        else
          value == expected
        end
      end
    end

    private def new_entry(table, rows = revision_rows(table))
      entry = {revision: rows.empty? ? 0 : rows.first.fetch('__id'), queries: {}}
      remember(entry, JSON.generate(REVISION_QUERY), REVISION_QUERY, rows)
      entry
    end

    def invalidate(table)
      entry = @tables.delete(table)
      return unless entry
      @queries -= entry[:queries].size
      @bytes -= entry[:queries].values.sum { |query| query[:bytes] }
    end

    # Only a contiguous, acknowledged append can preserve unrelated partitions.
    # A gap, unknown acknowledgement or lost response may include another
    # writer's changes and must invalidate the entire table as before.
    def inserted(table, row)
      entry = @tables[table]
      return unless entry
      unless row.is_a?(Hash) && Publication::Data.integer?(row['__id'], 1) && row['__id'] == entry[:revision] + 1
        return invalidate(table)
      end
      entry[:revision] = row.fetch('__id')
      entry[:queries].delete_if do |_key, query|
        next false if unrelated_partition?(query[:arguments], row)
        @queries -= 1
        @bytes -= query[:bytes]
        true
      end
    end

    def refresh!(only: nil)
      return if !only && @verification_io==@io_sequence
      @tables.keys.each do |table|
        next if only && !table.equal?(only)
        rows = revision_rows(table)
        if @tables.fetch(table)[:revision] != (rows.empty? ? 0 : rows.first.fetch('__id'))
          invalidate(table)
          @tables[table] = new_entry(table, rows)
        else
          # An acknowledged append may have invalidated the retained head.
          # This fresh SDK check already supplies its complete replacement.
          remember(@tables.fetch(table), JSON.generate(REVISION_QUERY), REVISION_QUERY, rows)
        end
      end
      @verification_io=@io_sequence if !only && @verification_io
    end

    # Nested authorization inside one archive verification may reuse the same
    # freshness check only while every intervening read stayed local. A real
    # SDK read/write breaks that proof, as does leaving this verification.
    def verify
      previous=@verification_io
      refresh!
      @verification_io=@io_sequence
      yield
    ensure
      @verification_io=previous
    end

    def writing!
      @io_sequence+=1
    end

    private

    def unrelated_partition?(arguments, row)
      # These immutable fields use exact integer/hex identifiers, not SQL
      # collation of arbitrary text or guessed semantics of complex filters.
      where = arguments[:where] || arguments['where']
      return false unless where.is_a?(Hash)
      %w[operation_key tournament_id publication_digest roster_generation].any? do |field|
        actual = row[field]
        expected = where[field]
        next false unless row.key?(field) && where.key?(field)
        values = expected.is_a?(Hash) && expected.keys == ['in'] ? expected['in'] : [expected]
        next false unless values.is_a?(Array) && !values.empty?
        values.all? do |value|
          if actual.is_a?(Integer) && value.is_a?(Integer)
            actual != value
          elsif actual.is_a?(String) && value.is_a?(String) &&
              /\A[0-9a-f]{64}\z/.match?(actual) && /\A[0-9a-f]{64}\z/.match?(value)
            actual != value
          else
            false
          end
        end
      end
    end

    def revision_rows(table)
      @io_sequence+=1
      rows = table.raw.select(**REVISION_QUERY).to_a
      raise Publication::Invalid, :invalid_document_page unless rows.size <= 1 &&
        rows.all? { |row| row.is_a?(Hash) && Publication::Data.integer?(row['__id'], 1) }
      rows
    end

    public

    class Table
      attr_reader :raw
      def initialize(raw, identity)
        @raw, @identity = raw, identity
      end

      def select(**arguments)
        scope = Thread.current[KEY]
        scope && scope.identity == @identity ? scope.select(self, arguments) : @raw.select(**arguments)
      end

      def document_rows(where, &block)
        scope = Thread.current[KEY]
        scope && scope.identity == @identity ? scope.document_rows(self, where, &block) : block.call
      end

      def insert(values)
        scope = Thread.current[KEY]
        scope = nil unless scope && scope.identity == @identity
        scope&.writing!
        begin
          row = @raw.insert(values)
        rescue Exception
          scope&.invalidate(self)
          raise
        end
        scope&.inserted(self, row)
        row
      end
    end

    class Provider
      def initialize(provider, identity)
        @provider, @identity, @tables, @lock = provider, identity, {}, Mutex.new
      end
      def available?; @provider.available?; end
      def fetch(name)
        @lock.synchronize { @tables[name] ||= Table.new(@provider.fetch(name), @identity) }
      end
    end
  end
end
