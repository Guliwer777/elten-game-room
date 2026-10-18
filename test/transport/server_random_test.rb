require_relative '../support/native_room_harness'
require_relative '../../games/farkle'
require_relative '../../lib/bot_turn_gate'

game = GameRoomGames::Farkle.new
room = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
session = room.start
assert(room.core.metadata['protocol'] == 8, 'older clients must not enter server-random tables')
assert(session['__server_random'] == 1, 'server randomness missing from the game')
context = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::LocalSecureSource.new, server_random: true)
status, plan = game.action_for({'action'=>'roll'}, room.replay('Alice'), 'Alice', context: context)
assert(status == :ok && plan.events.first.random_request, 'roll is not deferred')
rows = room.write('Alice', plan.events)
assert(rows.length == 1 && rows.first['value'].split(',').length == 6, 'dice not projected')
assert(room.view('Alice').calls[:random] == 1, 'draw must use one native random call')
assert(room.core.entries.last['origin'] == 'server', 'not a native random event')
room.assert_converged('server roll', expected_count: 1)
assert(room.replay('Alice').accepted_events.length == 1, 'game rejected server dice')

# A participant cannot manufacture a native origin inside their own packet.
forged = JSON.parse(JSON.generate(room.core.entries.last.dig('packet', 'context')))
forged['data']['events'][0]['value'] = '6,6,6,6,6,6'
room.view('Alice').stack_push(forged, message_id: SecureRandom.uuid)
room.assert_converged('forged context rejected', expected_count: 1)
ordinary = JSON.parse(JSON.generate(forged))
ordinary['data'].delete('random_request')
room.view('Alice').stack_push(ordinary, message_id: SecureRandom.uuid)
room.assert_converged('ordinary dice rejected', expected_count: 1)

# A lost response without a callback keeps the original request and result.
other = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
other.start
_, plan = game.action_for({'action'=>'roll'}, other.replay('Alice'), 'Alice', context: context)
gate = GameRoomBots::TurnController.new
lease = gate.acquire(session_id: other.session['__id'], actor: 'Alice', revision: [0,0])
gate.submitting(lease, events: plan.events)
other.broker.automatic_delivery = false
other.view('Alice').fail_next_push = :after
begin
  other.write('Alice', plan.events)
  raise 'lost response should raise'
rescue EltenAPI::LiveSessions::TimeoutError
  gate.submission_failed(lease)
end
stored = other.core.entries.last.dup
other.transports['Alice'].reconcile(other.table['__id'])
other.broker.deliver
assert(other.core.entries.last == stored, 'reconciliation drew again')
other.assert_converged('recovered roll', expected_count: 1)
events = other.events('Alice')
assert(gate.observe(session_id: other.session['__id'], events: events, confirmed_event_ids: events.map { |e| e['__id'] }, verified: true) == :confirmed,
  'bot gate failed to recognize its random request')
puts 'PASS server random: native provenance, one request, convergence, retry and bot gate'
