require_relative '../../lib/game_room_user_registry'

module UserRegistryShortPageContract
  def self.assert(value, message)
    raise message unless value
    @checks = @checks.to_i + 1
  end

  class Table
    attr_reader :queries, :rows
    attr_accessor :cap, :after_select, :repeat_page, :failure_at

    def initialize(cap:)
      @cap, @queries = cap, []
      @rows = (1..6).map do |id|
        {'__id' => id, 'registered_at' => 100, 'username' => "Player#{id}", '__insertion_user' => "Player#{id}"}
      end
      @rows[1]['__insertion_user'] = 'Spoofed'
    end

    def select(where: nil, order: nil, limit: nil, offset: nil, columns: nil)
      @queries << {where: where, order: order, limit: limit, offset: offset, columns: columns}
      raise IOError, 'later page unavailable' if @failure_at && @queries.length == @failure_at
      selected = @rows.select do |row|
        where.to_h.all? do |key, expected|
          if expected.is_a?(Hash)
            expected.all? { |operator, bound| operator == 'gte' ? row[key] >= bound : operator == 'lte' ? row[key] <= bound : raise(operator) }
          else
            row[key] == expected
          end
        end
      end
      order.to_a.reverse_each do |key, direction|
        selected = selected.sort_by { |row| row.fetch(key) }
        selected.reverse! if direction == 'desc'
      end
      selected = selected.drop(offset.to_i).first([limit || cap, cap].min)
      selected = selected.map { |row| columns ? row.slice(*columns) : row.dup }
      @after_select&.call(@queries.last, selected)
      selected
    end
  end

  failures = []
  [1, 2, 3, 1000].each do |cap|
    begin
      table = Table.new(cap: cap)
      registry = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
      wanted = ['player6', 'Player2', 'Player1', 'not registered']
      assert(registry.registered(wanted) == ['player6', 'Player1'], "cap=#{cap}: short page lost a verified candidate or accepted spoofing")
      count = table.queries.length
      assert(registry.registered(wanted) == ['player6', 'Player1'] && table.queries.length == count,
        "cap=#{cap}: completed lookup did not reuse bounded snapshot")
      assert(registry.registered([]).empty? && table.queries.length == count, 'empty candidates performed network reads')
      assert(table.queries.all? { |query| query[:limit] <= 1000 }, 'unbounded registry page')
    rescue StandardError => error
      failures << error.message
    end
  end
  begin
    table = Table.new(cap: 2)
    registry = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
    table.after_select = lambda do |query, _rows|
      next unless query[:columns] == ['__id'] && table.rows.length == 6
      table.rows << {'__id' => 7, 'registered_at' => 1, 'username' => 'Late', '__insertion_user' => 'Late'}
    end
    assert(registry.registered(['Player6', 'Late']) == ['Player6'], 'new registration escaped the initial read boundary')
    table.after_select = nil
    fresh = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
    assert(fresh.registered(['Late']) == ['Late'], 'a fresh snapshot missed a later registration')

    table = Table.new(cap: 2)
    registry = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
    table.failure_at = 3
    failed = begin; registry.registered(['Player1', 'Player6']); false; rescue IOError; true; end
    assert(failed, 'later-page error was treated as a partial successful registry')
    table.failure_at = nil
    assert(registry.registered(['Player1', 'Player6']) == ['Player1', 'Player6'], 'partial result was cached after failure')

    [:repeat, :reversed, :invalid_id, :non_array].each do |kind|
      table = Table.new(cap: 2)
      registry = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
      previous = nil
      table.after_select = lambda do |query, rows|
        next if query[:columns] == ['__id']
        case kind
        when :repeat then previous ? rows.replace(previous) : previous = rows.map(&:dup)
        when :reversed then rows.reverse!
        when :invalid_id then rows.first['__id'] = 0
        end
      end
      if kind == :non_array
        original = table.method(:select)
        table.define_singleton_method(:select) do |**query|
          rows = original.call(**query)
          query[:columns] == ['__id'] ? rows : nil
        end
      end
      failed = begin; registry.registered(['Player6']); false; rescue IOError; true; end
      assert(failed && table.queries.length <= 3, "#{kind}: malformed pagination did not fail closed promptly")
    end
  rescue StandardError => error
    failures << error.message
  end
  raise failures.join("\n") unless failures.empty?
  puts "PASS user registry short-page contract: #{@checks} assertions"
end
