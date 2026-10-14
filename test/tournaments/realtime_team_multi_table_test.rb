require_relative '../support/tournament_realtime_team_play'
include TournamentRealtimeTeamPlay
$stdout.sync = true
names = %w[Alice Bob Carol Dave Erin Frank Grace Henry]
with_fixture(game: 'axel_pong', names: names, players_per_match: 4, rematch: false,
  game_options: {'team_size' => 2, 'target' => 7}) do |fixture|
  record = nil
  with_declared_team_backend(fixture, 'Organizator') do |backend, _authority, _directory|
    record = backend.accept(preview: backend.preview_pairs(publication_ref: fixture.reference,
      pairs: names.each_slice(2).map { |pair| pair.map(&:downcase) }, team_template: [0, 1, 0, 1], intent_id: 'two-realtime-tables'))
  end
  intent = record['preview']['intent_id']
  path = File.join(fixture.directory, 'team-plans/fixed-teams-v1/execution-ft2-v1/state.json')
  with_declared_team_dispatch(fixture, record, 'Organizator') { |dispatcher| dispatcher.configure(intent_id: intent, max_tables: 2) }
  names.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| dispatcher.available(intent_id: intent, available: true) } }
  3.times { names.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| dispatcher.advance(intent_id: intent) } } }
  invited = JSON.parse(File.binread(path))
  assert_equal(2, invited['native']['cores'].size)
  assert_equal(2, invited['executions'].size)
  assert_equal(8, invited['busy'].size)
  assert(invited['executions'].values.all? { |execution| execution['start'].nil? }, 'Neither table may start without participant consent')
  names.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| assert_equal(:confirmed, dispatcher.accept(intent_id: intent)[:state]) } }
  names.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| dispatcher.advance(intent_id: intent) } }
  started = JSON.parse(File.binread(path))
  active = started['executions'].values.select { |execution| execution['start'] }
  assert_equal(2, active.size)
  assert_equal(2, active.map { |execution| execution['start']['native_uuid'] }.uniq.size)
  assignments = active.flat_map { |execution| execution['request']['players'].map { |person| person['account'] } }
  assert_equal(8, assignments.uniq.size, 'No player may occupy both simultaneous tables')
  indices = active.map do |execution|
    record['evidence']['plan']['matches'].index { |match| match['match_id'] == execution['request']['match_id'] && match['leg'] == execution['request']['leg'] }
  end
  indices.each_with_index do |index, number|
    result = play_realtime_team_match(fixture, record, index)
    assert_equal(2 * (number + 1), result[:status]['standings'].sum { |row| row['points'] })
    state = JSON.parse(File.binread(path))
    assert_equal(4 * (1 - number), state['busy'].size, 'Finishing must release only its own four seats')
    puts "PASS actual realtime result at table #{number + 1}"
  end
  completed = JSON.parse(File.binread(path))
  assert_equal({}, completed['busy'])
  assert_equal(2, completed['executions'].values.count { |execution| execution['result'] })
  3.times { names.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| dispatcher.advance(intent_id: intent) } } }
  queued = JSON.parse(File.binread(path))
  unfinished = queued['executions'].values.reject { |execution| execution['result'] }
  assert_equal(2, unfinished.size, 'Next disjoint matches must use both available tables')
  assert(unfinished.all? { |execution| execution['start'].nil? }, 'New matches require new explicit admissions')
  assert_equal(4, queued['native']['creates'].size, 'Each new match receives its own native table')
  people = unfinished.flat_map { |execution| execution['request']['players'].map { |person| person['account'] } }
  assert_equal(8, people.uniq.size)
end
puts 'PASS two realtime tables: automatic invitations, eight distinct players, two Starts, real team results, isolated busy release and automatic next batch awaiting consent'
