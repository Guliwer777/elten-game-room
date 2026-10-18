require_relative '../support/assertions'
require 'tmpdir'
require_relative '../support/tournament_server_plan_table'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/server_phase_plan'
require_relative '../../lib/tournaments/server_capacity'
require_relative '../../lib/tournaments/server_phase_store'
include GameRoomTest::Assertions
T = GameRoomTournaments

def candidate_for(count)
  game = GameRoomGames::TicTacToe.new
  roster = Array.new(count) { |i| format('player-%03d', i) }
  settings = {'format' => 'groups_knockout', 'participant_limit' => count,
    'players_per_match' => 2, 'game_options' => game.default_options,
    'group_advancement' => T::GroupAdvancement::COMPACT,
    'pairing' => 'all_combinations', 'rematch' => false}
  assert(T::ServerCapacity.validate!(registry: GameRoomGames::CATALOG, game_id: game.id, settings: settings))
  matches, groups = T::GroupSchedule.build(roster: roster, settings: settings, players_per_match: 2)
  matches = matches.map do |match|
    match.merge('match_id' => Digest::SHA256.hexdigest(JSON.generate([count, match])))
  end
  T::ServerPlanDocument.copy_document({'format' => 'groups_knockout', 'game_id' => game.id, 'game_options' => game.default_options,
    'roster' => roster, 'players_per_match' => 2, 'schedule_id' => 'c' * 64,
    'publication_digest' => 'b' * 64, 'roster_generation' => 'a' * 64,
    'publication_ref' => {'author' => roster.first, 'publication_key' => "capacity-#{count}"},
    'group_advancement' => T::GroupAdvancement::COMPACT,
    'groups' => T::GroupSchedule.metadata(groups, matches), 'matches' => matches,
    'dispatch_allowed' => false, 'start_allowed' => false, 'finalize_allowed' => false})
end

def receipts_for(candidate, draw: true)
  candidate.fetch('matches').map do |match|
    people = match.fetch('players')
    {'match_id' => match.fetch('match_id'), 'leg' => match.fetch('leg'),
      'summary' => {'participants' => people.sort, 'winners' => draw ? [] : [people.first],
        'draw' => draw, 'scores' => nil, 'event_count' => 9}}
  end
end

def standings_for(candidate, receipts)
  rows = receipts.map do |receipt|
    receipt.fetch('summary').slice('participants', 'winners', 'scores').merge(
      'id' => JSON.generate(receipt.values_at('match_id', 'leg')))
  end
  T::KnockoutStandings.calculate(candidate: candidate, units: candidate.fetch('roster'),
    results: rows, unit_key: 'players')
end

def read_back(document)
  candidate = document.fetch('candidate')
  anchor = {'operation_key' => T::ServerPhasePlan.digest(document), 'tournament_id' => 1,
    'publication_digest' => candidate.fetch('publication_digest'),
    'roster_generation' => candidate.fetch('roster_generation')}
  rows = T::ServerPlanDocument.encode(document, anchor: anchor)
  assert(rows.size <= T::ServerPlanDocument::MAX_PARTS + 1)
  assert(rows.all? { |row| row.fetch('payload').bytesize <= 2048 })
  rows = rows.each_with_index.map do |row, index|
    row.merge('__id' => index + 1, '__insertion_user' => 'player-000')
  end
  # New JSON objects model a later table read, not the original in-memory plan.
  decoded = T::ServerPlanDocument.decode(JSON.parse(JSON.generate(rows)), anchor: anchor, author: 'player-000')
  assert_equal(document, decoded)
  assert(decoded.frozen? && decoded.fetch('candidate').frozen?)
  decoded.fetch('candidate')
end

def verify_store_roundtrip(candidate, group_results, first, second, next_phase)
  Dir.mktmpdir('group-capacity-') do |directory|
    actor = 'player-000'
    table = TournamentServerPlanTableSupport::Table.new(user: -> { actor })
    receipts = {candidate.fetch('schedule_id') => group_results,
      first.fetch('schedule_id') => receipts_for(first),
      second.fetch('schedule_id') => receipts_for(second, draw: false)}
    build = lambda do
      journal = T::OperationJournal.new(directory: File.join(directory, actor), owner: actor,
        backend_identity: 'group-capacity-contract')
      T::ServerPhaseStore.new(table: table, journal: journal, user: -> { actor },
        source: -> { {'tournament_id' => 1, 'candidate' => JSON.parse(JSON.generate(candidate))} },
        results: ->(phase, _root) { {'results' => receipts.fetch(phase.fetch('schedule_id'), [])} })
    end
    parent = candidate
    [first, second, next_phase].each_with_index do |expected, index|
      before = table.insert_count
      actual = build.call.advance(expected_schedule_id: parent.fetch('schedule_id'))
      assert_equal(expected, actual.fetch('candidate'))
      assert(table.insert_count > before)
      actor = index.even? ? 'player-001' : 'player-000'
      count = table.insert_count
      cold = build.call.current
      assert_equal(actual, cold, 'Another participant cannot reconstruct the complete phase lineage')
      assert_equal(count, table.insert_count, 'Reading the lineage published a duplicate phase')
      assert_equal(index + 1, cold.fetch('phase_history').size)
      parent = expected
    end
  end
end

failures = []
[4, 16, 32, 64, 96, 128].each do |count|
  candidate = candidate_for(count)
  original = Marshal.dump(candidate)
  group_results = receipts_for(candidate)
  if count == 96
    # The 64 places comprise two from each group and sixteen wildcards.
    # Resolve the final eight groups normally so their third-placed players
    # have fewer original points than the first sixteen groups. This tests a
    # valid large snapshot without requiring a separate 276-match wildcard tie.
    resolved = candidate.fetch('groups').last(8).flat_map { |group| group.fetch('matches') }
    group_results.each do |receipt|
      next unless resolved.include?(receipt.fetch('match_id'))
      summary = receipt.fetch('summary')
      summary['winners'], summary['draw'] = [summary.fetch('participants').first], false
    end
  end
  first_document = T::ServerPhasePlan.build(candidate: candidate, results: group_results)
  first = read_back(first_document)
  snapshot = first.dig('knockout', 'qualification', 'snapshot')
  assert(snapshot, 'Drawn group stage did not produce a real tiebreak')
  snapshot_bytes = JSON.generate(snapshot).bytesize
  first_bytes = Marshal.dump(first)
  begin
    partial = standings_for(first, [])
    assert_equal('awaiting_results', partial.dig('qualification_progress', 'state'))
    tied_results = receipts_for(first)
    view = standings_for(first, tied_results)
    assert(%w[tie_requires_resolution seeding_tie_requires_resolution].include?(view.dig('qualification_progress', 'state')))
    second = read_back(T::ServerPhasePlan.build(candidate: first, results: tied_results))
    assert_equal(2, second.dig('knockout', 'qualification', 'attempt'))
    assert_equal(snapshot, second.dig('knockout', 'qualification', 'snapshot'), 'Drawn games changed original group evidence')
    decisive = receipts_for(second, draw: false)
    done = standings_for(second, decisive)
    assert_equal('ready_knockout', done.dig('qualification_progress', 'state'))
    next_phase = read_back(T::ServerPhasePlan.build(candidate: second, results: decisive))
    target = T::GroupAdvancement.target(count, policy: T::GroupAdvancement::COMPACT)
    assert_equal(target, next_phase.fetch('roster').size, 'Qualified players disappeared')
    qualified = done.dig('qualification_progress', 'projection', 'qualified')
    assert_equal(qualified.sort, next_phase.fetch('roster').sort)
    assert(!next_phase.fetch('knockout').key?('qualification'))
    assert_equal(target / 2, next_phase.fetch('matches').size)
    assert_equal(original, Marshal.dump(candidate), 'Group candidate was mutated')
    assert_equal(first_bytes, Marshal.dump(first), 'Tiebreak candidate was mutated')
    verify_store_roundtrip(candidate, group_results, first, second, next_phase) if count >= 96
    puts JSON.generate(players: count, matches: group_results.size, snapshot_bytes: snapshot_bytes, status: 'PASS')
  rescue T::Publication::Invalid => error
    failure = {players: count, matches: group_results.size, snapshot_bytes: snapshot_bytes, status: 'FAIL', code: error.code}
    failures << failure
    puts JSON.generate(failure)
  end
end
assert_equal([], failures, 'Server-accepted tournament cannot read or advance its group tiebreak')

# This is not an enlargement of the publication/transport limits. The larger
# in-memory snapshot shape is still bounded, and every phase must fit the
# existing document budget before it can be published.
assert_equal(256, T::ServerCapacity::MAX_MATCHES)
assert_equal(262_144, T::ServerPlanDocument::MAX_BYTES)
assert_equal(:json_budget, assert_raises(T::Publication::Invalid) do
  T::GroupTiebreak.send(:copy_snapshot, {'nodes' => Array.new(65_536)})
end.code)
assert_equal(:json_budget, assert_raises(T::Publication::Invalid) do
  T::GroupTiebreak.send(:copy_snapshot, {'text' => 'x' * 1_048_576})
end.code)
assert_equal(:json_budget, assert_raises(T::Publication::Invalid) do
  T::ServerPlanDocument.copy_document({'nodes' => Array.new(16_384)})
end.code)
assert_equal(:json_budget, assert_raises(T::Publication::Invalid) do
  T::ServerPlanDocument.copy_document({'text' => 'x' * T::ServerPlanDocument::MAX_BYTES})
end.code)
oversized = candidate_for(128)
oversized['notes'] = 'x' * T::ServerPlanDocument::MAX_BYTES
assert_raises(T::Publication::Invalid) do
  T::ServerPhasePlan.build(candidate: oversized, results: receipts_for(oversized))
end
puts 'PASS bounded group tiebreaks: authenticated document reread, empty/full view, repeated draws, advancement and oversized rejection'
