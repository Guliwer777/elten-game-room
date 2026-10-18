require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/assertions'
require_relative '../../lib/tournaments/group_stage'
require_relative '../../lib/tournaments/group_standings'
include GameRoomTest::Assertions
T = GameRoomTournaments

# Real plan producers and both result projections; no fabricated standings,
# network, or claim that this is a live tournament.
def project(configuration, plan, results)
  before = JSON.generate([configuration, plan, results])
  stage = T::GroupStage.calculate(configuration: configuration, results: results)
  candidate = {
    'group_advancement' => configuration.fetch(:advancement),
    'groups' => plan.fetch('groups').map do |group|
      group.slice('id', 'units', 'places').merge('matches' => group.fetch('matches').map { |match| match.fetch('id') })
    end,
    'matches' => plan.fetch('groups').flat_map do |group|
      group.fetch('matches').map do |match|
        {'match_id' => match.fetch('id'), 'leg' => match.fetch('leg'), 'accounts' => match.fetch('participants')}
      end
    end
  }
  matches = candidate.fetch('matches').to_h { |match| [match.fetch('match_id'), match] }
  wired = results.map do |result|
    match = matches.fetch(result.fetch('id'))
    result.merge('id' => JSON.generate([match.fetch('match_id'), match.fetch('leg')]))
  end
  summary = T::GroupStandings.calculate(candidate: candidate, units: configuration.fetch(:participants),
    results: wired, unit_key: 'accounts', players_per_match: 2)
  assert_equal(stage.fetch('cross_seeding'), summary.fetch('cross_seeding'), 'Both group result paths must preserve the same ties')
  assert_equal(stage.fetch('qualified'), summary.fetch('qualified'), 'Both group result paths must select the same players')
  assert_equal(before, JSON.generate([configuration, plan, results]), 'Result projection mutated its inputs')
  [stage, summary]
end

configuration = {participants: (1..10).map { |i| "player#{i}" }, group_count: nil,
  places_per_group: nil, advancement: T::GroupAdvancement::COMPACT,
  players_per_match: 2, pairing: 'all_combinations', rematch: false}
plan = T::GroupPlan.build(**configuration)
groups = plan.fetch('groups')
assert_equal([4, 3, 3], groups.map { |group| group.fetch('units').size })
wildcards = groups.map { |group| group.fetch('units')[2] }
automatic = groups.flat_map { |group| group.fetch('units').first(2) }
checks = 0

%w[higher lower].each do |order|
  [false, true].repeated_permutation(groups.size) do |floats|
    results = groups.each_with_index.flat_map do |group, index|
      group.fetch('matches').map do |match|
        winner = match.fetch('participants').min_by { |unit| group.fetch('units').index(unit) }
        scores = match.fetch('participants').to_h do |unit|
          score = unit == winner ? 2 : 1
          score = 3 - score if order == 'lower'
          [unit, floats.fetch(index) ? score.to_f : score]
        end
        match.slice('id', 'participants').merge('winners' => [winner], 'scores' => scores, 'score_order' => order)
      end
    end
    [results, results.reverse].each do |ordered|
      stage, summary = project(configuration, plan, ordered)
      assert_equal('seeding_tie_requires_resolution', stage.fetch('state'))
      assert_equal('seeding_tie_requires_resolution', summary.fetch('group_state'))
      cross = stage.fetch('cross_seeding')
      assert_equal(wildcards.sort, cross.fetch('unresolved').sort,
        "Equal sporting scores were separated by representation: #{order}/#{floats}")
      assert_equal([], cross.fetch('seeds'), 'An unresolved tie must not create knockout seeds')
      assert_equal(automatic.sort, stage.fetch('qualified').sort)
      assert_equal([2], cross.fetch('comparison').map { |row| row.fetch('played') }.uniq)
      assert_equal(groups.first.fetch('units').last, cross.fetch('comparison').first.fetch('excluded'))

      grouped = groups.map { |group| ordered.select { |row| group.fetch('matches').any? { |match| match.fetch('id') == row.fetch('id') } } }
      explicit_order = wildcards.each_with_index.to_h { |unit, index| [unit, index + 1] }
      resolved = T::CompactGroupSeeding.build(groups: stage.fetch('groups'), results_by_group: grouped, wildcard_order: explicit_order)
      assert_equal('ready', resolved.fetch('state'))
      assert_equal((automatic + wildcards.first(2)).sort, resolved.fetch('seeds').sort,
        'Only an explicit sporting tiebreak may separate equal numeric scores')
      checks += 1
    end
  end
end

# Do not repair hash equality by converting scores to Float: distinct large
# integers must remain distinct, including when lower scores are better.
%w[higher lower].each do |order|
  results = groups.each_with_index.flat_map do |group, index|
    group.fetch('matches').map do |match|
      winner = match.fetch('participants').min_by { |unit| group.fetch('units').index(unit) }
      scores = match.fetch('participants').to_h do |unit|
        score = 2**60 + index + (unit == winner ? 2 : 1)
        [unit, order == 'lower' ? -score : score]
      end
      match.slice('id', 'participants').merge('winners' => [winner], 'scores' => scores, 'score_order' => order)
    end
  end
  stage, summary = project(configuration, plan, results)
  assert_equal('knockout_candidate', stage.fetch('state'))
  assert_equal('ready_knockout', summary.fetch('group_state'))
  assert_equal((automatic + wildcards.last(2)).sort, stage.fetch('qualified').sort,
    'Rounding large scores manufactured a wildcard tie or changed the qualifiers')
  assert(stage.fetch('cross_seeding').fetch('comparison').all? { |row| row.fetch('score_for').is_a?(Integer) })
  checks += 1
end

# Missing small-point scores still cannot be treated as zero to break a tie.
without_scores = groups.flat_map do |group|
  group.fetch('matches').map do |match|
    winner = match.fetch('participants').min_by { |unit| group.fetch('units').index(unit) }
    match.slice('id', 'participants').merge('winners' => [winner])
  end
end
stage, = project(configuration, plan, without_scores)
assert_equal(wildcards.sort, stage.fetch('cross_seeding').fetch('unresolved').sort)
assert_equal('awaiting_results', T::GroupStage.calculate(configuration: configuration, results: without_scores.drop(1)).fetch('state'))
puts "PASS compact wildcard numeric ties: #{checks} complete producer/projection cases, mixed Integer/Float, score direction, input order, explicit tiebreaks, large integers and missing scores"
