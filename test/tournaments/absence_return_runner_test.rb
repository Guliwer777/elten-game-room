require_relative '../support/tournament_forfeit_native'
require_relative '../../lib/table_activity_repository'

TournamentForfeitNative.with_fixture do |f|
  f.start
  h = f.h
  runner = runner_for(h)
  runner.instance_variable_set(:@tournament_presence, f.services.fetch('Alice').method(:presence_context))
  runner.instance_variable_set(:@completion_observer, ->(session, replay, events) { f.services.fetch('Alice').observe(h.table, session, replay, events) })
  clock = [0.0]
  runner.define_singleton_method(:tournament_observation_time) { clock.first }
  step(h, runner)
  initial = h.core.entries.size
  20.times { clock[0] += 15; step(h, runner) }
  assert_equal(initial, h.core.entries.size, 'Full presence wrote periodic records')
  h.as('Bob') { h.view('Bob').leave }
  step(h, runner)
  snapshot = h.as('Alice') { h.repositories['Alice'].snapshot_for(h.session) }
  assert(snapshot.session['__frozen'], 'Confirmed departure did not pause the tournament')
  assert_equal(['Bob'], snapshot.session.fetch('__tournament_presence').fetch('absent'))
  assert_equal({}, snapshot.session.fetch('__controllers'), 'Departure installed a replacement bot')
  4.times { clock[0] += 15; step(h, runner) }
  assert_equal(60_000, h.as('Alice') { h.repositories['Alice'].snapshot_for(h.session).session.dig('__tournament_presence', 'totals_ms', 'Bob') })
  assert(h.join('Bob'))
  step(h, runner)
  snapshot = h.as('Alice') { h.repositories['Alice'].snapshot_for(h.session) }
  assert(!snapshot.session['__frozen'], 'Returning player did not resume the game')
  assert_equal(60_000, snapshot.session.dig('__tournament_presence', 'totals_ms', 'Bob'))
  assert_equal(:ok, submit(h, runner).first, 'A normal first move failed after the return')
  h.as('Bob') { h.view('Bob').leave }
  step(h, runner)
  15.times { clock[0] += 15; step(h, runner) }
  assert(!h.as('Alice') { h.repositories['Alice'].snapshot_for(h.session).session['__aborted'] }, 'Forfeit occurred before the cumulative limit')
  clock[0] += 15
  step(h, runner)
  snapshot = h.as('Alice') { h.repositories['Alice'].snapshot_for(h.session) }
  assert(GameRoomTournamentPresence.ended?(snapshot.session), 'Cumulative five minutes did not end the 1v1 match')
  assert_equal('Bob', snapshot.session.dig('__tournament_presence', 'loser'))
  activity = TableActivityRepository.new(server_tables: Object.new, transport: h.transports['Alice'])
  ended = activity.entries_for(h.table).select { |entry| entry.kind == 'game_aborted' }
  assert_equal(1, ended.size)
  assert_equal('Bob', ended.first.subject)
  assert_equal('tournament_absence', ended.first.reason)
  assert_equal('Bob loses by forfeit after five minutes of absence.', activity.text_for(ended.first, game_name: ->(id) { id }))
  row = f.services.fetch('Alice').instance_variable_get(:@bindings).fetch(h.table['__id'])
  captured = GameRoomTournaments::OrdinaryMatchResults.capture(registry: GameRoomGames::CATALOG,
    binding: row.first, session: snapshot.session, replay: h.replay('Alice'), events: snapshot.events)
  assert_equal(['alice'], captured['summary']['winners'])
  assert_equal(%w[alice bob], captured['summary']['participants'])
  assert(!h.replay('Alice').finished?, 'Administrative result forged a model victory')
  h.as('Alice') { f.services.fetch('Alice').collect(row + [captured]) }
  result = h.as('Alice') { f.services.fetch('Alice').result_view }
  assert_equal(['alice'], result['results'].first['summary']['winners'])
  count = f.documents.insert_count
  h.as('Alice') { f.services.fetch('Alice').collect(row + [captured]) }
  assert_equal(count, f.documents.insert_count, 'Retry duplicated the exported result')
ensure
  runner&.close
end
puts 'PASS native tournament absence: no presence polling, pause, return, cumulative 300 s, normal move and one exported 1v1 result'
