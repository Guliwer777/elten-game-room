require_relative 'tournament_server_plan_table'
module ReadinessPlanTableSupport
  class Table < TournamentServerPlanTableSupport::Table
    def initialize(user:,clock:)
      super(user:user)
      @clock=clock
    end
    def insert(values)
      # The fake SDK stamps the stored row before acknowledgement loss.
      super(values.merge('__insertion_time'=>@clock.call))
    end
    def select(where:,limit:,order:nil)
      on_select&.call
      selected=rows.select do |row|
        where.all? do |key,value|
          if value.is_a?(Hash)
            value.key?('in') ? value.fetch('in').include?(row[key]) : row[key]>=value.fetch('gte')
          else
            row[key]==value
          end
        end
      end
      selected=selected.sort_by{|row|-row['__id']} if order==[['__id','desc']]
      selected=selected.sort_by{|row|row['__id']} if order==[['__id','asc']]
      selected.first(limit)
    end
  end
end
