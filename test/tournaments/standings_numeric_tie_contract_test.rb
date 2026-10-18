require_relative '../support/assertions'
require_relative '../../lib/tournaments/standings_ranking'
include GameRoomTest::Assertions
T = GameRoomTournaments
checks = 0
policies = [%w[head_to_head difference scored], %w[difference scored head_to_head]]

verify = lambda do |units, results, points, expected, criteria|
  input = JSON.generate([units, results, points, criteria])
  # These are accepted numeric values, not malformed input bypassing the model.
  T::Standings.calculate(units: units, results: results, points: points)
  ranked = T::StandingsRanking.calculate(units: units, results: results, points: points, criteria: criteria)
  assert_equal(expected, ranked.to_h { |row| [row['unit'], row['place']] }, 'Numerically equal standings must share a rank')
  assert_equal(input, JSON.generate([units, results, points, criteria]), 'Ranking changed caller data')
  assert(ranked.frozen? && ranked.all?(&:frozen?), 'Ranking lost immutable output')
  checks += 1
end

policies.each do |criteria|
  %w[higher lower].each do |order|
    [%w[a b], %w[b a]].each do |units|
      [0, 17, -17, 2**60].each do |number|
        rows = [{'id' => 'draw', 'participants' => units, 'winners' => [],
          'scores' => {'a' => number, 'b' => number.to_f}, 'score_order' => order}]
        verify.call(units, rows, T::Standings::MATCH_POINTS, {'a' => 1, 'b' => 1}, criteria)
      end
    end
  end
end

# Equal small-point differences and scores must not split two disconnected
# groups; their head-to-head evidence is intentionally incomplete, not zero.
policies.each do |criteria|
  %w[higher lower].each do |order|
    rows = [
      {'id' => 'ac', 'participants' => %w[a c], 'winners' => ['a'], 'scores' => {'a' => 2, 'c' => 1}, 'score_order' => order},
      {'id' => 'bd', 'participants' => %w[b d], 'winners' => ['b'], 'scores' => {'b' => 2.0, 'd' => 1.0}, 'score_order' => order}
    ]
    [%w[a b c d], %w[d c b a]].each do |units|
      verify.call(units, rows, T::Standings::MATCH_POINTS, {'a' => 1, 'b' => 1, 'c' => 3, 'd' => 3}, criteria)
    end
  end
end

# Different exact large values cannot be collapsed by converting to Float.
policies.each do |criteria|
  %w[higher lower].each do |order|
    rows = [
      {'id' => 'ac', 'participants' => %w[a c], 'winners' => ['a'], 'scores' => {'a' => 2**60 + 1, 'c' => 0}, 'score_order' => order},
      {'id' => 'bd', 'participants' => %w[b d], 'winners' => ['b'], 'scores' => {'b' => (2**60).to_f, 'd' => 0}, 'score_order' => order}
    ]
    expected = order == 'higher' ? {'a' => 1, 'b' => 2, 'c' => 4, 'd' => 3} : {'b' => 1, 'a' => 2, 'c' => 3, 'd' => 4}
    [%w[a b c d], %w[d c b a]].each { |units| verify.call(units, rows, T::Standings::MATCH_POINTS, expected, criteria) }
  end
end

mixed_points = {'win' => 2.0, 'draw' => 1, 'loss' => 0}
rows = [
  {'id' => 'ac', 'participants' => %w[a c], 'winners' => []},
  {'id' => 'ad', 'participants' => %w[a d], 'winners' => []},
  {'id' => 'be', 'participants' => %w[b e], 'winners' => ['b']}
]
policies.each do |criteria|
  [%w[a b c d e], %w[e d c b a]].each do |units|
    verify.call(units, rows, mixed_points, {'a' => 1, 'b' => 1, 'c' => 3, 'd' => 3, 'e' => 5}, criteria)
  end
end

# All five players have four points. A has four Integer draw points; the
# others have Float win points. The complete balanced mini-table is tied too.
units = %w[a b c d e]
rows = units.drop(1).map { |other| {'id' => "a#{other}", 'participants' => ['a', other], 'winners' => []} }
[%w[b c], %w[c d], %w[d e], %w[e b]].each do |winner, loser|
  rows << {'id' => "#{winner}#{loser}", 'participants' => [winner, loser], 'winners' => [winner]}
end
[%w[b d], %w[c e]].each { |pair| rows << {'id' => pair.join, 'participants' => pair, 'winners' => []} }
policies.each do |criteria|
  [units, units.reverse].each { |people| verify.call(people, rows, mixed_points, units.to_h { |unit| [unit, 1] }, criteria) }
end

# Joining the equal points group must allow the ordinary head-to-head rule
# to decide it; grouping by JSON number representation would skip that rule.
rows = [
  {'id' => 'ab', 'participants' => %w[a b], 'winners' => ['b']},
  {'id' => 'ac', 'participants' => %w[a c], 'winners' => []},
  {'id' => 'ad', 'participants' => %w[a d], 'winners' => []}
]
policies.each do |criteria|
  [%w[a b c d], %w[d c b a]].each { |people| verify.call(people, rows, mixed_points, {'b' => 1, 'a' => 2, 'c' => 3, 'd' => 3}, criteria) }
end
puts "PASS numeric standings equality: #{checks} cases, Integer/Float points, mini-table, difference, scores and exact large values"
