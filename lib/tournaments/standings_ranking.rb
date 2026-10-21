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
      numeric_groups(table) { |row| row['points'] }.each do |tied|
        groups = [tied]
        criteria.each do |criterion|
          groups = groups.flat_map do |group|
            next [group] if group.size == 1
            keys = values(group, results, points, criterion)
            next [group] unless keys
            numeric_groups(group) { |row| keys.fetch(row['unit']) }
          end
        end
        groups.each do |group|
          place = ranked.size + 1
          # Provisional ties list players with games still in hand first.
          # This is display order, not an extra qualification criterion.
          group.sort_by { |row| [row['played'], row['unit']] }.each { |row| ranked << row.merge('place' => place) }
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
        return nil unless group.all? do |row|
          eligible=results.count { |result|result['participants'].include?(row['unit']) && result['resolution']!='all_zero' }
          eligible.positive? && row['scored_matches']==eligible
        end
        group.to_h do |row|
          value = criterion == 'difference' ? row['score_for'] - row['score_against'] : row['score_for']
          [row['unit'], row['score_order'] == 'lower' ? -value : value]
        end
      end
    end

    # Hash equality distinguishes Integer and Float keys (0 and 0.0), while
    # sporting scores compare numerically. Keep exact large integers intact.
    def self.numeric_groups(rows)
      rows.map { |row| [yield(row), row] }.sort_by { |value, _row| -value }
        .chunk_while { |left, right| (left.first <=> right.first).zero? }
        .map { |group| group.map(&:last) }
    end
    private_class_method :values, :numeric_groups
  end
end
