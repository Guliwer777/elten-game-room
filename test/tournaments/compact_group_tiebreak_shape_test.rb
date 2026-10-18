require_relative '../support/assertions'
require_relative '../../lib/tournaments/knockout_schedule'
require_relative '../../lib/tournaments/group_stage'
include GameRoomTest::Assertions
T = GameRoomTournaments

# Producer-generated compact groups and pure sporting summaries. This is not
# a live game or a substitute for authenticated result-receipt validation.
configuration = {participants: (1..10).map { |i| "player#{i}" }, group_count: nil,
  places_per_group: nil, advancement: T::GroupAdvancement::COMPACT,
  players_per_match: 2, pairing: 'all_combinations', rematch: false}
groups = T::GroupPlan.build(**configuration).fetch('groups')
assert_equal([4, 3, 3], groups.map { |group| group.fetch('units').size })
results = groups.map do |group|
  group.fetch('matches').map do |match|
    winner = match.fetch('participants').min_by { |unit| group.fetch('units').index(unit) }
    match.slice('id', 'participants').merge('winners' => [winner])
  end
end
stage = T::GroupStage.calculate(configuration: configuration, results: results.flatten(1))
assert_equal('seeding_tie_requires_resolution', stage.fetch('state'))
snapshot = T::GroupTiebreak.snapshot(summary: {'groups' => stage.fetch('groups'), 'group_results' => results},
  candidate: {'group_advancement' => configuration[:advancement]})
first = T::GroupTiebreak.build(snapshot: snapshot, attempt: 1)
draws = first.fetch('matches').map { |match| match.merge('winners' => []) }
progress = T::GroupTiebreak.progress(plan: first, results: draws)
assert_equal('seeding_tie_requires_resolution', progress.fetch('state'))
plan = T::GroupTiebreak.build(snapshot: progress.fetch('snapshot'), attempt: 2)
metadata = plan.slice('round', 'seeds', 'players_per_match', 'generation', 'qualification')
  .merge('phase_digest' => 'a' * 64, 'parent_plan_digest' => 'b' * 64)
valid = T::KnockoutSchedule.matches(metadata: metadata, generation: 'roster')
bytes = JSON.generate(metadata)
prefix = %w[qualification snapshot]
wildcard = metadata.dig(*prefix, 'wildcard_order').keys.first
assert(wildcard, 'The fixture must exercise an existing wildcard tiebreak order')
paths = [prefix + ['results_by_group', 0, 0], prefix + ['results_by_group', 0, 0, 'participants'],
  prefix + ['results_by_group', 0, 0, 'winners'], prefix + ['groups', 0, 'id'], prefix + ['wildcard_order', wildcard]]
checks = 0
paths.each do |keys|
  [nil, true, false, 0, 0.0, '', [], {}].each do |value|
    malformed = JSON.parse(bytes)
    parent = keys[0...-1].inject(malformed) { |node, key| node.fetch(key) }
    parent[keys.last] = value
    before = JSON.generate(malformed)
    error = assert_raises(T::Publication::Invalid) { T::KnockoutSchedule.matches(metadata: malformed, generation: 'roster') }
    assert(error.code.is_a?(Symbol), 'Malformed qualification metadata needs a typed refusal')
    assert_equal(before, JSON.generate(malformed), 'A refusal must not repair the sporting snapshot')
    checks += 1
  end
end
assert_equal(valid, T::KnockoutSchedule.matches(metadata: metadata, generation: 'roster'))
assert_equal(bytes, JSON.generate(metadata))
resolved = plan.fetch('matches').map { |match| match.merge('winners' => [match.fetch('participants').min]) }
final = T::GroupTiebreak.progress(plan: plan, results: resolved)
assert_equal('ready_knockout', final.fetch('state'))
assert_equal(8, final.fetch('projection').fetch('qualified').size)
puts "PASS compact group tiebreak shapes: #{checks} typed refusals, unchanged 4/3/3 group plans and resolved wildcard qualification"
