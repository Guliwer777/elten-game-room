require_relative '../support/pong_client'
require_relative '../../lib/tournaments/game_result'
require_relative '../../lib/tournaments/standings'

# Full existing client lifecycle with an isolated peer channel. No engine
# mutation or invented point commands; only client-agreed goals are replayed.
h = PongHarness.new(options: {'target' => 7})
events = 0
begin
  h.advance(220)
  host = h.clients.fetch('Alice')
  7.times do
    h.advance(380) unless events.zero?
    assert(h.clients.values.none?(&:paused), 'Clients must be ready before serving')
    server = h.players[host.engine.server]
    if server == 'Alice'
      h.surfaces['Bob'].controls['move'] = 1
      h.press('Alice')
    else
      assert(h.clients['Alice'].request_hurry, 'The opponent must be allowed to hurry the actual server')
    end
    1600.times do
      h.advance(1)
      break if host.context_data['pong_point']
    end
    value = host.context_data['pong_point']
    assert(value && value.start_with?("#{events}:0"), 'Actual clients did not agree on the expected goal')
    context = GameRoomGames::ActionContext.new(table_owner: 'Alice', local_data: host.context_data)
    selection = h.rules.automatic_action(h.replay, 'Alice', context: context)
    status, plan = h.rules.action_for(selection, h.replay, 'Alice', context: context)
    assert(status == :ok && plan.events.size == 1 && plan.events.first.value.to_s == value,
      'Agreed point must pass the ordinary game action contract')
    h.accept_point(value)
    events += 1
    h.surfaces['Bob'].controls['move'] = 0
    assert(host.context_data['pong_point'].nil?, 'A committed point must not remain pending')
  end
  assert(h.replay.finished? && h.replay.winner == 'Alice', 'Full Pong match did not finish')
  players = h.players.map { |name| {'username' => name, 'account' => name.downcase, 'team' => nil} }
  result = GameRoomTournaments::GameResult.from_replay(game: h.rules, replay: h.replay,
    players: players, options: h.rules.options_from_json(h.session['options']), event_count: events,
    result_policy: GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
  assert(result['scores'] == {'alice' => 7, 'bob' => 0} && result['winners'] == ['alice'],
    'Tournament projection must retain actual client points and winner')
ensure
  h.close
end
assert(h.network.values.none?(&:connected?), 'Pong channels leaked')
puts 'PASS full Pong clients: genuine serves/misses and game-owned serve timeout, seven acknowledged points, tournament score export and cleanup; isolated transport, not local tournament execution'
