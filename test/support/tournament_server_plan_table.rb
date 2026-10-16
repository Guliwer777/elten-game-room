module TournamentServerPlanTableSupport
  class Table
    attr_reader :rows, :insert_count
    attr_accessor :on_insert, :on_select
    def initialize(user:)
      @user = user
      @rows = []
      @insert_count = 0
      @lock = Mutex.new
    end
    def insert(values)
      insert_as(values, @user.call)
    end
    def for_user(user)
      server = self
      Object.new.tap do |client|
        client.define_singleton_method(:insert) { |values| server.insert_as(values, user) }
        client.define_singleton_method(:select) { |**query| server.select(**query) }
      end
    end
    def insert_as(values, user)
      copy = JSON.parse(JSON.generate(values))
      row = @lock.synchronize do
        @insert_count += 1
        copy.merge('__id' => @insert_count, '__insertion_user' => user).tap { |value| @rows << value }
      end
      @on_insert&.call(row)
      row
    end
    def select(where:, limit:, order: nil)
      @on_select&.call
      selected = @rows.select do |row|
        where.all? do |key, value|
          if value.is_a?(Hash)
            value.all? { |operator, bound| operator == 'in' ? bound.include?(row[key]) : operator == 'gte' ? row[key] >= bound : row[key] <= bound }
          else
            row[key] == value
          end
        end
      end
      if order
        selected = selected.sort_by { |row| row.fetch('__id') }
        selected.reverse! if order.first.last == 'desc'
        selected.first(limit)
      else
        selected.first(limit).reverse
      end
    end
  end
end
