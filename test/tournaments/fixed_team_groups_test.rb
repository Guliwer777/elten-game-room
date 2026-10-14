require_relative '../support/tournament_fixed_teams'
require_relative '../../lib/tournaments/local_fixed_team_standings'
require_relative '../../lib/tournaments/knockout_phase'
include TournamentFixedTeamsSupport
names = %w[Ala Anna Bartek Beata Celina Cezary Darek Dorota]
automatic = ARGV.include?('--automatic')
settings = automatic ? {group_advancement: T::GroupAdvancement::AUTOMATIC} : {group_count: 2, places_per_group: 1}
context, service, reference = fixture(names: names, rematch: false, **settings)
with_backend(context) do |backend, reopen, _session, _authority, _directory|
  pairs = names.each_slice(2).to_a
  preview = backend.preview_pairs(publication_ref: reference, pairs: pairs, team_template: TEMPLATE, intent_id: 'team-groups')
  record = backend.accept(preview: preview)
  candidate = record['preview']['source']['candidate']
  assert_equal([%w[team-001 team-003], %w[team-002 team-004]], candidate['groups'].map { |group| group['units'] })
  assert_equal(2, candidate['matches'].size)
  assert_equal(2, record['evidence']['plan']['matches'].size)
  candidate['matches'].each do |match|
    assert_equal(4, match['players'].size)
    assert_equal(2, match['unit_ids'].size)
  end
  assert_equal(record, reopen.call.readback(intent_id: 'team-groups'))
  empty = T::LocalFixedTeamStandings.build(record: record, executions: [])
  assert_equal('awaiting_results', empty['group_state'])
  assert_equal([1, 1, 1, 1], empty['standings'].map { |row| row['place'] })
  # Projection-only receipts, never written into authoritative game storage.
  intent = record['preview']['intent_id']
  receipts = record['evidence']['plan']['matches'].map do |match|
    teams = match['players'].map { |person| person['team'] }.uniq
    {'record_intent' => intent, 'result' => {'record_intent' => intent, 'match_id' => match['match_id'],
      'leg' => match['leg'], 'summary' => {'winner' => teams.first, 'scores' => {teams.first => 10, teams.last => -2}}}}
  end
  complete = T::LocalFixedTeamStandings.build(record: record, executions: receipts)
  assert_equal(automatic ? 'ready_knockout' : 'awaiting_seeding', complete['group_state'])
  assert_equal(automatic ? 4 : 2, complete['qualified'].size)
  assert_equal([%w[team-001 team-004], %w[team-003 team-002]], complete['cross_seeding']['pairs']) if automatic
  if automatic
    # Pure projection only: these summaries do not authorize stored results.
    phase = T::KnockoutPhase.build(record: record, receipts: receipts.map { |r| r['result'] })
    assert_equal(complete['cross_seeding']['pairs'], phase['plan']['matches'].map { |m| m['participants'] })
    assert_equal(false, phase['dispatch_allowed'])
    # Exercise the shared schedule and v2 contract purely, without storing a
    # fabricated result/approval or authorizing a native game.
    approval = {'preview' => phase}
    derived = T::KnockoutSchedule.candidate(parent: record, approval: approval)
    source = record['evidence']['source'].reject { |key, _| key == 'groups' }
    source = source.merge(derived.slice('membership', 'roster_generation', 'roster_digest', 'schedule_id', 'rematch', 'knockout'))
    source['matches'] = derived['matches'].map { |m| m.slice('match_id', 'leg', 'unit_ids').merge('accounts' => m['players'],
      'window_ids' => source['windows'].map { |w| w['id'] }) }
    T::FixedTeamPlanContract.source!(source)
    assert_equal(2, source['matches'].size)
  end
  assert_equal([1, 2, 1, 2], complete['standings'].map { |row| row['place'] })
  assert_equal([2, 0, 2, 0], complete['standings'].map { |row| row['points'] })
  assert_equal(%w[group-1 group-2], complete['standings'].map { |row| row['group'] }.uniq)
  bad = Marshal.load(Marshal.dump(preview))
  bad['source']['candidate']['groups'].first['units'][0] = 'team-004'
  assert_raises(T::Publication::Invalid) { backend.accept(preview: bad) }
end
puts 'PASS fixed-team groups: own signup, indivisible teams, accepted/cold plan and separate qualification tables'
