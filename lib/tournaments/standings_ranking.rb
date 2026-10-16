require_relative 'standings'
module GameRoomTournaments
  class StandingsRanking
    CRITERIA = %w[head_to_head difference scored].freeze
    # Recompute from verified results; never persist a second result or infer
    # numeric scores for a game that does not provide them.
    def self.calculate(units:, results:, points:, criteria:)
      unless [%w[head_to_head difference scored], %w[difference scored head_to_head]].include?(criteria)
        raise Publication::Invalid, :invalid_ranking_policy
      end
      table = Standings.calculate(units: units, results: results, points: points)
      ranked = []
      table.group_by { |row| row['points'] }.sort_by { |value, _| -value }.each do |_, tied|
        groups = [tied]
        criteria.each do |criterion|
          groups = groups.flat_map do |group|
            next [group] if group.size == 1
            keys = values(group, results, points, criterion)
            next [group] unless keys
            group.group_by { |row| keys.fetch(row['unit']) }.sort_by { |value, _| -value }.map(&:last)
          end
        end
        groups.each do |group|
          place = ranked.size + 1
          group.sort_by { |row| row['unit'] }.each { |row| ranked << row.merge('place' => place) }
        end
      end
      Publication::Data.freeze_tree(Publication::Data.copy(ranked, max_bytes: 262_144, max_nodes: 16_384, max_depth: 8))
    end

    def self.values(group, results, points, criterion)
      if criterion == 'head_to_head'
        units = group.map { |row| row['unit'] }
        direct = results.select { |result| (result['participants'] - units).empty? }
        # An incomplete/unbalanced mini-table must not decide a final tie.
        counts = units.combination(2).map do |pair|
          direct.count { |result| (pair - result['participants']).empty? }
        end
        return nil unless counts.all?(&:positive?) && counts.uniq.size == 1
        Standings.calculate(units: units, results: direct, points: points).to_h { |row| [row['unit'], row['points']] }
      else
        # Compare small points only if every tied unit has numeric scores for
        # every played match. Missing scores are not treated as zero.
        return nil unless group.all? { |row| row['played'].positive? && row['scored_matches'] == row['played'] }
        group.to_h do |row|
          value = criterion == 'difference' ? row['score_for'] - row['score_against'] : row['score_for']
          [row['unit'], row['score_order'] == 'lower' ? -value : value]
        end
      end
    end
    private_class_method :values
  end
end
