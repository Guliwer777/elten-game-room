require_relative '../support/audio_ball_client'
require_relative '../../lib/tournaments/game_result'
require_relative '../../lib/tournaments/standings'

# Actual client physics and peer acknowledgement through the isolated channel
# harness. Durable actions use the game's rules; this is not a live network or
# the local tournament Runner, whose realtime execution gate remains closed.
h = AudioBallHarness.new(options: {'sets_to_win' => 2})
begin
  h.advance(12)
  assert(h.clients.values.none?(&:paused), 'Both clients must complete readiness')
  # Set scores 7:3, 2:7, 7:4; win_point uses actual shots and legal defense.
  sets = [['Bob'] * 3 + ['Alice'] * 7,
    ['Alice'] * 2 + ['Bob'] * 7, ['Bob'] * 4 + ['Alice'] * 7]
  sets.each_with_index do |winners, set_index|
    if set_index.positive?
      h.advance_for(GameRoomGames::AudioBall::SET_BREAK + 1)
      h.advance(12)
    end
    winners.each do |winner|
      old_rally = h.replay.state[:rally]
      h.win_point(winner)
      assert(h.replay.state[:rally] == old_rally + 1, 'Each agreed goal must commit once')
      assert(h.clients.values.all? { |client| client.context_data['audio_ball_point'].nil? },
        'Every client must consume the durable point before another rally')
      h.advance_for(5.8) unless h.replay.finished?
    end
    assert(h.replay.finished? == (set_index == 2), 'An earlier set must not finish the match')
  end
  assert(h.replay.winner == 'Alice' && h.replay.state[:sets] == [2, 1], 'Actual set winner changed')
  players = h.players.map { |name| {'username' => name, 'account' => name.downcase, 'team' => nil} }
  arguments = {game: h.game, replay: h.replay, players: players,
    options: h.game.options_from_json(h.session['options']), event_count: h.events.size}
  result = GameRoomTournaments::GameResult.from_replay(**arguments,
    result_policy: GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
  assert(result['scores'] == {'alice' => 16, 'bob' => 14}, 'Small points lost earlier sets')
  assert(result['winners'] == ['alice'] && !result['draw'], 'Tournament outcome differs from the clients')
  table = GameRoomTournaments::Standings.calculate(units: %w[alice bob],
    results: [result.slice('participants', 'winners', 'scores', 'score_order').merge('id' => 'client-game')],
    points: GameRoomTournaments::Standings::MATCH_POINTS)
  assert(table.map { |row| row['points'] } == [2, 0], 'Tournament points must be 2/0')
  assert(h.replay.accepted_events.size == h.events.size, 'No rejected public event may be included')
ensure
  h.close
end
assert(h.network.values.none?(&:connected?), 'Realtime channels leaked after closing')
puts 'PASS actual Audio Ball clients: three sets, 30 physics/peer-agreed points, game-owned result and 2/0 standings, channel cleanup; isolated transport, no tournament execution claim'
