require_relative '../../support/session_runner'
require_relative '../../../games/bridge'

class NoBridgeClientRandom
  def roll(**); raise 'Bridge used client entropy in a native game'; end
end

game = GameRoomGames::Bridge.new
%w[rubber duplicate].each do |variant|
  h = NativeRoomHarness.new(game:game, options:game.default_options.merge('variant'=>variant))
  h.start
  context = GameRoomGames::ActionContext.new(random_source:NoBridgeClientRandom.new, server_random:true, table_owner:'Alice')
  h.view('Alice').next_random_values = (1..16).to_a
  selection = {'kind'=>'command', 'action'=>'deal'}
  status, plan = game.action_for(selection, h.replay('Alice'), 'Alice', context:context)
  assert(status == :ok, 'no server deal')
  h.broker.automatic_delivery = false
  h.view('Alice').fail_next_push = :after
  assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Alice', plan.events) }
  h.transports['Alice'].reconcile(h.table['__id'])
  h.broker.automatic_delivery = true
  h.broker.deliver(duplicate:true)
  h.assert_converged(variant, expected_count:1)
  assert(h.view('Alice').calls[:random] == 1, 'lost ACK rerolled the deck')
  first = h.replay('Alice')
  assert(first.state[:hands].values.flatten.uniq.size == 52, 'server deal lost cards')
  assert(first.accepted_events.size == 1, 'server deal rejected')
  original = h.events('Alice').first
  legacy = original.reject { |key, _| key == '__server_random' }
  assert(game.replay(h.session, [legacy], h.repositories['Alice']).state == first.state, 'legacy seed replay changed')
  assert_raises(ArgumentError) { h.write('Alice', [GameRoomGames::EventCommand.new(action:'deal', value:original['value'])]) }
  4.times do
    actor = h.replay('Alice').current_player
    h.submit(actor, {'kind'=>'command','action'=>'call','call'=>'P'})
  end
  h.submit('Alice', selection, context:context)
  h.assert_converged("#{variant} next deal", expected_count:6)
  assert(h.replay('Alice').state[:dealer] == (first.state[:dealer] + 1) % 4, 'dealer rotation changed')
  assert(h.view('Alice').calls[:random] == 2, 'ordinary next deal used extra request')
  bad = NativeRoomHarness.new(game:game)
  bad.start
  bad.write('Alice', [GameRoomServerRandom.command(action:'deal', count:1, sides:2)])
  assert(bad.replay('Alice').accepted_events.empty?, 'attacker-selected server recipe accepted')
end
puts 'PASS Bridge public server deals: one request, no local entropy, lost ACK, recipe validation, legacy replay, next dealer'
