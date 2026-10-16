require_relative 'publication'

module GameRoomTournaments
  # Bounded keyset pagination for append-only documents. The upper ID fixes the
  # read boundary, not a cross-table transaction. Called only on a worker.
  module ServerDocumentRows
    PAGE_SIZE = 1000
    MAX_ROWS = 65_536
    MAX_BYTES = 33_554_432
    module_function

    def read_keys(table, keys, guard: -> {})
      keys.uniq.each_slice(96).flat_map do |slice|
        read(table, where: {'operation_key' => {'in' => slice}}, guard: guard)
      end
    end

    def read(table, where:, guard: -> {}, author: nil, after_id: 0)
      raise Publication::Invalid, :invalid_document_cursor unless Publication::Data.integer?(after_id)
      where = where.merge('__id' => {'gte' => after_id + 1}) if after_id > 0
      guard.call
      read = -> { read_complete(table, where: where, guard: guard, after_id: after_id) }
      rows = table.respond_to?(:document_rows) ? table.document_rows(where, &read) : read.call
      guard.call
      author ? owned(rows, author) : rows
    end

    def read_complete(table, where:, guard:, after_id:)
      guard.call
      upper = page(table, where, [['__id', 'desc']], 1)
      guard.call
      return [] if upper.empty?
      upper_id = upper.first.fetch('__id')
      cursor, bytes, rows = after_id, 0, []
      loop do
        guard.call
        values = page(table, where.merge('__id' => {'gte' => cursor + 1}), [['__id', 'asc']], PAGE_SIZE)
        guard.call
        raise Publication::Invalid, :incomplete_document_read if values.empty?
        values.each do |row|
          id = row.fetch('__id')
          raise Publication::Invalid, :unordered_document_read unless id > cursor
          break if id > upper_id
          if id == upper_id && row != upper.first
            raise Publication::Invalid, :changed_document_read
          end
          bytes += JSON.generate(row).bytesize
          raise Publication::Invalid, :document_read_limit if rows.size >= MAX_ROWS || bytes > MAX_BYTES
          rows << row
          cursor = id
        end
        break if cursor == upper_id
        raise Publication::Invalid, :incomplete_document_read if values.last['__id'] > upper_id
      end
      rows
    end

    def owned(rows, author)
      account = Publication::Data.account(author).downcase
      rows.select { |row| row['__insertion_user'].is_a?(String) && row['__insertion_user'].downcase == account }
    end

    def page(table, where, order, limit)
      rows = table.select(where: where, order: order, limit: limit)
      unless rows.is_a?(Array) && rows.size <= limit && rows.all? { |row| row.is_a?(Hash) && Publication::Data.integer?(row['__id'], 1) }
        raise Publication::Invalid, :invalid_document_page
      end
      Publication::Data.copy(rows, max_bytes: 4_194_304, max_nodes: 65_536, max_depth: 8)
    end
  end
end
