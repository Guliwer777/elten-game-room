# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_ft2b1_entry'
require_relative '../../lib/tournaments/local_fixed_team_standings'
require_relative '../../lib/tournaments/local_fixed_team_progress'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = GameRoomTournaments
fixture = F.fixture(GameRoomTest::TemporaryDirectory.create('s'))
record = fixture[:record]
intent = record['preview']['intent_id']
empty = T::LocalFixedTeamStandings.build(record: record, executions: [])
assert_equal(false, empty['complete'])
assert_equal(6, empty['remaining'])
assert_equal([0, 0, 0], empty['standings'].map { |row| row['played'] })
# Projection-only fixtures; these do not enter authoritative execution storage.
rows = record['evidence']['plan']['matches'].map do |match|
  teams = match['players'].map { |person| person['team'] }.uniq
  {'record_intent' => intent, 'request' => match.merge('window' => match['windows'].first), 'result' => {'record_intent' => intent,
    'match_id' => match['match_id'], 'leg' => match['leg'],
    'summary' => {'winner' => teams.first, 'scores' => {teams.first => 10, teams.last => -20}}}}
end
partial = T::LocalFixedTeamStandings.build(record: record, executions: rows.first(5))
assert_equal(false, partial['complete'])
assert_equal(1, partial['remaining'])
whole = T::LocalFixedTeamStandings.build(record: record, executions: rows)
assert_equal(true, whole['complete'])
assert_equal(0, whole['remaining'])
assert_equal(6, whole['results'].size)
assert_equal([4, 4, 4], whole['standings'].map { |row| row['played'] })
assert_equal(6, whole['standings'].sum { |row| row['wins'] })
assert_equal(12, whole['standings'].sum { |row| row['points'] })
whole['standings'].each { |row| assert_equal(row['wins'] * 2 + row['draws'], row['points']) }
assert_equal(6, whole['standings'].sum { |row| row['losses'] })
assert_equal(-60, whole['standings'].sum { |row| row['score_for'] })
assert_equal(-60, whole['standings'].sum { |row| row['score_against'] })
assert_raises(T::Publication::Invalid) { T::LocalFixedTeamStandings.build(record: record, executions: rows + [rows.first]) }
bad = Marshal.load(Marshal.dump(rows))
bad.first['result']['match_id'] = 'outside-plan'
assert_raises(T::Publication::Invalid) { T::LocalFixedTeamStandings.build(record: record, executions: bad) }
bad = Marshal.load(Marshal.dump(rows))
bad.first['result']['summary']['scores']['unit-C'] = 100
assert_raises(T::Publication::Invalid) { T::LocalFixedTeamStandings.build(record: record, executions: bad) }
document = {'executions' => rows.each_with_index.to_h { |row, index| [index.to_s, row] }, 'native' => {'cores' => []}}
progress = T::LocalFixedTeamProgress.build(document: document, record: record, actor: 'ala', registry: F::REGISTRY, now: fixture[:now])
assert_equal(true, progress['complete'])
assert_equal(nil, progress['recommendation'])
assert_equal(whole['standings'], progress['standings'])
fixture[:program].finalize; fixture[:program].class.app_runtime.close
puts 'PASS whole tournament standings: empty, partial, all legs, negative points, duplicate and unrelated result rejection, completed progress'
