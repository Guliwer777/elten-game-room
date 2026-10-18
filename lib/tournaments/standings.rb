# encoding: UTF-8
require_relative 'publication'

module GameRoomTournaments
  # Game-neutral arithmetic. Callers supply verified results of one tournament.
  class Standings
    Data = Publication::Data
    MATCH_POINTS = {'win' => 2, 'draw' => 1, 'loss' => 0}.freeze
    def self.calculate(units:, results:, points: nil)
      if points
        unless points.is_a?(Hash) && points.keys.sort == %w[draw loss win] &&
            points.values.all? { |value| value.is_a?(Integer) && value.between?(0, 1_000_000) ||
              value.is_a?(Float) && value.finite? && value.between?(0, 1_000_000) }
          raise Publication::Invalid, :invalid_points_policy
        end
        points = Data.freeze_tree(Data.copy(points))
      end
      unless units.is_a?(Array) && units.size.between?(2, 256) && units.uniq.size == units.size &&
          results.is_a?(Array) && results.size <= 256
        raise Publication::Invalid, :invalid_standings
      end
      units.each { |id| Data.text!(id, bytes: 256) }
      rows = Data.copy(results, max_bytes: 262_144, max_nodes: 16_384, max_depth: 8)
      ids = []
      rows.each do |result|
        unless result.is_a?(Hash) && (result.keys - %w[id participants winners scores score_order places]).empty? &&
            (!result.key?('score_order') || %w[higher lower].include?(result['score_order']))
          raise Publication::Invalid, :invalid_standings
        end
        Data.text!(result['id'], bytes: 256)
        people, winners, scores = result.values_at('participants', 'winners', 'scores')
        unless !ids.include?(result['id']) && people.is_a?(Array) && people.size >= 2 && people.uniq == people &&
            (people - units).empty? && winners.is_a?(Array) && winners.uniq == winners && (winners - people).empty? &&
            (scores.nil? || (scores.is_a?(Hash) && scores.keys.sort == people.sort &&
              scores.values.all? { |score| score.is_a?(Integer) || (score.is_a?(Float) && score.finite?) }))
          raise Publication::Invalid, :invalid_standings
        end
        if result.key?('places')
          places=result['places']
          unless places.is_a?(Array) && !places.empty? && places.all? { |group| group.is_a?(Array) && !group.empty? && group.all? { |unit| people.include?(unit) } } &&
              places.flatten.size==people.size && places.flatten.sort==people.sort && places.first==winners
            raise Publication::Invalid, :invalid_standings
          end
        end
        ids << result['id']
      end
      orders = rows.select { |result| result['scores'] }.map { |result| result.fetch('score_order', 'higher') }.uniq
      raise Publication::Invalid, :invalid_standings if orders.size > 1
      explicit_order = rows.any? { |result| result.key?('score_order') } && orders.first
      table = units.sort.map do |unit|
        own = rows.select { |result| result['participants'].include?(unit) }
        scored = own.select { |result| result['scores'] }
        {'unit' => unit, 'played' => own.size, 'wins' => own.count { |r| r['winners'].include?(unit) },
          'losses' => own.count { |r| !r['winners'].empty? && !r['winners'].include?(unit) },
          'draws' => own.count { |r| r['winners'].empty? }, 'scored_matches' => scored.size,
          'score_for' => scored.empty? ? nil : scored.sum { |r| r['scores'].fetch(unit) },
          'score_against' => scored.empty? ? nil : scored.sum { |r| r['scores'].reject { |id, _| id == unit }.values.sum }}
      end
      if points
        table.each do |row|
          unit=row['unit']
          row['points'] = rows.select{|result|result['participants'].include?(unit)}.sum do |result|
            (result['participants']-[unit]).sum{|opponent|points.fetch(comparison(result,unit,opponent))}
          end
        end
      end
      table.each { |row| row['score_order'] = explicit_order } if explicit_order
      Data.freeze_tree(Data.copy(table, max_bytes: 262_144, max_nodes: 16_384, max_depth: 8))
    end

    def self.comparison(result,unit,opponent)
      if result.key?('places')
        own=result['places'].index { |group| group.include?(unit) }
        other=result['places'].index { |group| group.include?(opponent) }
        return own==other ? 'draw' : own<other ? 'win' : 'loss'
      end
      winners=result['winners']
      return 'draw' if winners.empty?
      own_win,other_win=winners.include?(unit),winners.include?(opponent)
      # The game's winner is authoritative, even when small points measure
      # rallies rather than sets. Co-winners share a place.
      return 'draw' if own_win && other_win
      return 'win' if own_win
      return 'loss' if other_win
      scores=result['scores']
      return 'draw' unless scores
      order=scores.fetch(unit)<=>scores.fetch(opponent)
      order=-order if result.fetch('score_order','higher')=='lower'
      order.zero? ? 'draw' : order.positive? ? 'win' : 'loss'
    end
    private_class_method :comparison
  end
end
