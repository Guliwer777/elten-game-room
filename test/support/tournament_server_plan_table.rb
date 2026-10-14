module TournamentServerPlanTableSupport
  class Table
    attr_reader :rows, :insert_count
    attr_accessor :on_insert, :on_select
    def initialize(user:)
      @user = user
      @rows = []
      @insert_count = 0
    end
    def insert(values)
      @insert_count += 1
      copy = JSON.parse(JSON.generate(values))
      row = copy.merge('__id' => @insert_count, '__insertion_user' => @user.call)
      @rows << row
      @on_insert&.call(row)
      row
    end
    def select(where:, limit:)
      @on_select&.call
      key=where['operation_key']
      @rows.select { |row| key.is_a?(Hash) ? key.fetch('in').include?(row['operation_key']) : row['operation_key']==key }.first(limit).reverse
    end
  end
end
