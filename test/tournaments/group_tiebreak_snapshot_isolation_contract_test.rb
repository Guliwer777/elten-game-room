require_relative '../support/assertions'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/server_phase_plan'
include GameRoomTest::Assertions

T = GameRoomTournaments
roster = Array.new(128) { |index| format('member-%03d', index) }
settings = {'pairing' => 'all_combinations', 'rematch' => false,
  'group_advancement' => T::GroupAdvancement::COMPACT}
matches, groups = T::GroupSchedule.build(roster: roster, settings: settings, players_per_match: 2)
matches = matches.map { |match| match.merge('match_id' => Digest::SHA256.hexdigest(JSON.generate(match))) }
source = T::ServerPlanDocument.copy_document({'format' => 'groups_knockout',
  'roster' => roster, 'matches' => matches, 'groups' => T::GroupSchedule.metadata(groups, matches),
  'group_advancement' => settings.fetch('group_advancement'), 'players_per_match' => 2,
  'schedule_id' => 'a' * 64, 'publication_digest' => 'b' * 64, 'roster_generation' => 'c' * 64,
  'publication_ref' => {'author' => roster.first, 'publication_key' => 'snapshot-isolation'}})
receipts = lambda do |candidate, drawn|
  candidate.fetch('matches').map do |match|
    {'match_id' => match.fetch('match_id'), 'leg' => match.fetch('leg'),
      'summary' => {'participants' => match.fetch('players'),
        'winners' => drawn ? [] : [match.fetch('players').first], 'scores' => nil}}
  end
end
first_document = T::ServerPhasePlan.build(candidate: source, results: receipts.call(source, true))
first = first_document.fetch('candidate')
plan = T::GroupTiebreak.from_metadata(first.fetch('knockout'))
snapshot = plan.dig('qualification', 'snapshot')
assert_equal(:json_budget, assert_raises(T::Publication::Invalid) { T::Publication::Data.copy(snapshot) }.code,
  'The independent fixture must actually exceed the old 4096-node copy budget')
frozen_before = Marshal.dump([source, first, plan])
first_progress = T::GroupTiebreak.progress(plan: plan, results: [])
second_progress = T::GroupTiebreak.progress(plan: plan, results: [])
assert_equal(first_progress, second_progress)
assert(!first_progress.fetch('snapshot').equal?(second_progress.fetch('snapshot')))
assert(!first_progress.fetch('snapshot').equal?(snapshot))

# A consumer may annotate its mutable progress snapshot. It must neither
# mutate the accepted plan nor leak into another view or the next phase.
first_row = first_progress.dig('snapshot', 'groups').first.dig('qualification', 'standings').first
first_row['points'] = 999
first_progress.dig('snapshot', 'groups').first['units'].first.replace('changed-unit')
first_progress.dig('snapshot', 'results_by_group').first.first['winners'] << 'changed-winner'
assert_equal(snapshot, second_progress.fetch('snapshot'))
assert_equal(snapshot, T::GroupTiebreak.progress(plan: plan, results: []).fetch('snapshot'))
assert_equal(frozen_before, Marshal.dump([source, first, plan]))

draws = receipts.call(first, true)
draw_copy = Marshal.dump(draws)
second_document = T::ServerPhasePlan.build(candidate: first, results: draws)
assert_equal(second_document, T::ServerPhasePlan.build(candidate: first, results: draws.reverse),
  'Receipt delivery order changed a deterministic phase')
second = second_document.fetch('candidate')
assert_equal(2, second.dig('knockout', 'qualification', 'attempt'))
assert_equal(snapshot, second.dig('knockout', 'qualification', 'snapshot'))
assert_equal(draw_copy, Marshal.dump(draws))
assert_equal(frozen_before, Marshal.dump([source, first, plan]))
assert(!(first.fetch('matches').map { |match| match['match_id'] } & second.fetch('matches').map { |match| match['match_id'] }).any?,
  'A new tiebreak attempt reused a previous match identity')
assert_raises(FrozenError) { second.dig('knockout', 'qualification', 'snapshot', 'groups').clear }

# Real decisive matches end the tie without modifying original group points.
third_document = T::ServerPhasePlan.build(candidate: second, results: receipts.call(second, false))
third = third_document.fetch('candidate')
assert(!third.fetch('knockout').key?('qualification'))
assert_equal(128, third.fetch('roster').size)
assert_equal(64, third.fetch('matches').size)
assert_equal(snapshot, second.dig('knockout', 'qualification', 'snapshot'))

# The copied proof is still checked. Neither a forged task nor a future
# attempt number can become an accepted phase through the larger copy limit.
forged = T::Publication::Data.copy(first.fetch('knockout'), max_bytes: 262_144, max_nodes: 16_384, max_depth: 16)
forged.fetch('qualification').fetch('tasks').first.fetch('units')[0] = 'intruder'
assert_equal(:phase_changed, assert_raises(T::Publication::Invalid) { T::GroupTiebreak.from_metadata(forged) }.code)
assert_equal(:invalid_knockout_configuration, assert_raises(T::Publication::Invalid) do
  T::GroupTiebreak.build(snapshot: snapshot, attempt: 256)
end.code)
incomplete = draws.drop(1)
assert_equal(:phase_results_incomplete, assert_raises(T::Publication::Invalid) do
  T::ServerPhasePlan.build(candidate: first, results: incomplete)
end.code)
duplicate = draws + [draws.first]
assert_equal(:invalid_phase_results, assert_raises(T::Publication::Invalid) do
  T::ServerPhasePlan.build(candidate: first, results: duplicate)
end.code)

# Server envelopes are independently bounded and authenticate one whole copy.
anchor = {'operation_key' => T::ServerPhasePlan.digest(second_document), 'tournament_id' => 9,
  'publication_digest' => second.fetch('publication_digest'), 'roster_generation' => second.fetch('roster_generation')}
rows = T::ServerPlanDocument.encode(second_document, anchor: anchor).each_with_index.map do |row, index|
  row.merge('__id' => index + 1, '__insertion_user' => roster.first)
end
assert_equal(second_document, T::ServerPlanDocument.decode(rows.reverse, anchor: anchor, author: roster.first))
assert_raises(T::Publication::Invalid) do
  T::ServerPlanDocument.decode(rows.each_with_index.map { |row, i| i == 1 ? row.merge('__insertion_user' => roster.last) : row },
    anchor: anchor, author: roster.first)
end
assert_equal(:incomplete_plan_document, assert_raises(T::Publication::Invalid) do
  T::ServerPlanDocument.decode(rows.drop(1), anchor: anchor, author: roster.first)
end.code)
assert_equal(frozen_before, Marshal.dump([source, first, plan]))
puts 'PASS independent large tiebreak: detached progress, deterministic repeats, unchanged group scores, strict proof and bounded server copy'
