require_relative '../support/mille_private'
require_relative '../../lib/saved_game_archive'

h, runners = MillePrivateTest.create
before = h.replay('Alice').state[:hands]['Alice'].dup
h.broker.automatic_delivery = false
h.view('Alice').fail_next_push = :after
replay = h.replay('Alice')
_, plan = h.game.action_for({'kind' => 'command', 'action' => 'draw'}, replay, 'Alice')
begin
  h.write('Alice', plan.events)
  raise 'timeout not raised'
rescue EltenAPI::LiveSessions::TimeoutError
end
entry = h.core.entries.last.dup
remaining = h.view('Alice').pools.first.state['remaining']
h.transports['Alice'].reconcile(h.table['__id'])
h.broker.deliver(duplicate: true)
assert(h.core.entries.last == entry, 'uncertain draw was repeated')
assert(h.view('Alice').pools.first.state['remaining'] == remaining, 'uncertain draw consumed two cards')
assert(h.replay('Alice').state[:hands]['Alice'].size == before.size + 1, 'recovered hand count wrong')
MillePrivateTest.assert_private(h)
raw = JSON.parse(JSON.generate(entry['packet']))
raw.merge!('origin' => 'server_pool', 'pool' => entry['pool'])
count = h.events('Bob').size
h.view('Alice').stack_push(raw, message_id: SecureRandom.uuid)
h.broker.deliver
assert(h.events('Bob').size == count, 'client forged a native pool receipt')
reveal = h.game.legal_actions(h.replay('Alice'), 'Alice').find { |a| a['action'] == 'discard' }
_, plan = h.game.action_for(reveal, h.replay('Alice'), 'Alice')
h.view('Alice').fail_next_push = :after
begin
  h.write('Alice', plan.events)
  raise 'reveal timeout not raised'
rescue EltenAPI::LiveSessions::TimeoutError
end
h.transports['Alice'].reconcile(h.table['__id'])
h.broker.deliver(duplicate: true)
MillePrivateTest.assert_private(h)
assert(h.replay('Alice').state[:discard] == [reveal['card']], 'uncertain reveal discarded twice')
archive = GameRoomSavedGameArchive.new(ProgramDouble.new(h.broker.endpoint('Alice')), owner: 'Alice')
begin
  archive.put(game: h.game, table: h.table, snapshot: h.repositories['Alice'].snapshot_for(h.session), repository: h.repositories['Alice'])
  raise 'private archive accepted'
rescue GameRoomTournamentMarker::SavingDisabled => error
  assert(error.message == 'Tournament games cannot be saved or resumed from a saved game.', 'wrong archive failure')
end
# A new start cannot silently change a private table into public hands.
start = h.core.entries.find { |e| e['packet']['kind'] == 'game_started' }['packet']
forged = JSON.parse(JSON.generate(start))
forged['data'].delete('private_cards')
forged['data']['session_id'] += 1
h.view('Alice').stack_push(forged, message_id: SecureRandom.uuid)
h.broker.deliver
assert(h.repositories['Bob'].session_for_table(h.table, force: true)['__id'] == h.session['__id'], 'privacy downgrade accepted')
h.users.each { |user| h.game.surface_spec(h.replay(user), user) }
runners.each_value(&:close)
puts 'PASS private integrity: lost replies, duplicate delivery, forged receipts, save guard, downgrade and surfaces'

# Native receipts may arrive after the table owner has changed. The account
# that took/revealed a card must retain that action across the control boundary.
h, runners = MillePrivateTest.create
h.broker.automatic_delivery = false
replay = h.replay('Alice')
_, plan = h.game.action_for({'kind' => 'command', 'action' => 'draw'}, replay, 'Alice')
h.write('Alice', plan.events)
h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |p| p.user == 'Bob' })
h.broker.deliver(duplicate: true)
MillePrivateTest.tick(h, runners)
MillePrivateTest.assert_private(h)
assert(h.replay('Alice').state[:hands]['Alice'].size == 7, 'host transfer rejected an already accepted draw')
choice = h.game.legal_actions(h.replay('Alice'), 'Alice').find { |action| action['action'] == 'discard' }
_, plan = h.game.action_for(choice, h.replay('Alice'), 'Alice')
assert_raises(GameRoomNetworkErrors::GamePaused) { h.write('Alice', plan.events) }
h.instance_variable_set(:@session, h.repositories['Alice'].snapshot_for(h.session).session)
h.write('Alice', plan.events)
h.view('Bob').transfer_ownership(h.view('Bob').participants.find { |p| p.user == 'Alice' })
h.broker.deliver(duplicate: true)
MillePrivateTest.tick(h, runners)
MillePrivateTest.assert_private(h)
assert(h.replay('Bob').state[:discard] == [choice['card']], 'host transfer rejected an already accepted reveal')
runners.each_value(&:close)
puts 'PASS private receipts across host transfer: delayed draw and reveal delivery'
