require_relative '../support/tournament_individual_execution'
require_relative '../../lib/game_simulation'
include TournamentIndividualExecutionSupport

# Pure public-history projection, not a realtime client/transport test.
def project_realtime(game, players, options, sides, teams: nil)
  repository = GameRoomSimulation::Repository.new(players)
  session = {'__players' => players, 'player_one' => players.first,
    '__insertion_user' => players.first, 'options' => JSON.generate(options)}
  events = []
  if game.id == 'audio_ball'
    events << {'__id' => 1, 'action' => 'audio_ball_start', 'value' => '0',
      '__insertion_user' => players.first, 'created_at' => 0}
  end
  sides.each_with_index do |side, rally|
    events << {'__id' => events.size + 1,
      'action' => game.id == 'audio_ball' ? 'audio_ball_point' : 'pong_point',
      'value' => "#{rally}:#{side}", '__insertion_user' => players.first,
      'created_at' => (rally + 1) * 10}
  end
  replay = game.replay(session, events, repository)
  assert(replay.finished?, 'The public fixture must finish under actual game rules')
  planned = players.each_with_index.map do |name, seat|
    {'username' => name, 'account' => name.downcase, 'team' => teams && teams[seat]}
  end
  arguments = {game: game, replay: replay, players: planned, options: options, event_count: events.size}
  [T::GameResult::RESULT_EXPORT_POLICY, T::GameResult::DRAW_RESULT_POLICY].each do |policy|
    old = T::GameResult.from_replay(**arguments, result_policy: policy)
    assert_equal(nil, old['scores'])
    assert(!old.key?('score_order'), 'Historical receipts must retain their original fields')
  end
  result = T::GameResult.from_replay(**arguments, result_policy: T::GameResult::CURRENT_RESULT_POLICY)
  assert_equal('higher', result['score_order'])
  result
end

pong = GameRoomGames::CATALOG.build('axel_pong')
options = pong.normalize_options('target' => 7)
single = project_realtime(pong, %w[Alpha Beta], options, [1, 1] + [0] * 7)
assert_equal({'alpha' => 7, 'beta' => 2}, single['scores'])
assert_equal(['alpha'], single['winners'])

players = %w[Alpha Beta Gamma Delta]
options = pong.normalize_options('team_size' => 2, 'target' => 7)
options = pong.with_team_assignment(options, players: players, seats: [0, 1, 0, 1])
doubles = project_realtime(pong, players, options, [1, 1] + [0] * 7, teams: %w[red blue red blue])
assert_equal({'red' => 7, 'blue' => 2}, doubles['scores'])
assert_equal(['red'], doubles['winners'])

audio = GameRoomGames::CATALOG.build('audio_ball')
# Three actual sets: 7:3, 2:7, 7:4. Final display is 7:4 and sets are 2:1;
# tournament small points must include all sets, giving 16:14.
sides = [1] * 3 + [0] * 7 + [0] * 2 + [1] * 7 + [1] * 4 + [0] * 7
multi = project_realtime(audio, %w[Alpha Beta], audio.normalize_options('sets_to_win' => 2), sides)
assert_equal({'alpha' => 16, 'beta' => 14}, multi['scores'])
assert_equal(['alpha'], multi['winners'])
# Winning sets decide the match even if the losing player scored more rallies.
# 8:6, 0:7, 10:8 => 18:21, while Alpha wins two sets to one.
close_set = [1] * 6 + [0] * 8
long_set = [1] * 6 + [0] * 6 + [1, 0, 1, 0, 0, 0]
unequal = project_realtime(audio, %w[Alpha Beta], audio.normalize_options('sets_to_win' => 2), close_set + [1] * 7 + long_set)
assert_equal({'alpha' => 18, 'beta' => 21}, unequal['scores'])
assert_equal(['alpha'], unequal['winners'])
table = T::Standings.calculate(units: %w[alpha beta],
  results: [unequal.slice('participants', 'winners', 'scores', 'score_order').merge('id' => 'sets-decide')], points: T::Standings::MATCH_POINTS)
assert_equal('alpha', table.first['unit'])
assert_equal(2, table.first['points'])
puts 'PASS realtime public-result projection: Pong singles/doubles totals once, Audio Ball all sets, historical policies unchanged; execution gate retained'
