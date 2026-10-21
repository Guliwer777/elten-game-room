require_relative '../support/tournament_ft2b1_entry'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/game_result'
require_relative '../../lib/game_simulation'
include GameRoomTest::Assertions
registry = GameRoomGames::CATALOG
expected = {
  'axel_pong'=>['higher',11,0], 'audio_ball'=>['higher',7,0],
  'mille_bornes'=>['higher',5000,0], 'tysiac'=>['higher',1000,0],
  'cat_head_tail'=>['higher',100,0], 'farkle'=>['higher',1000,0],
  'categories'=>['higher',50,0], 'spades'=>['higher',300,0],
  'quiz'=>['higher',15,0], 'uno'=>['lower',0,500],
  'rummy'=>['higher',1000,0], 'domino'=>['lower',0,100],
  'mexican_train'=>['lower',0,100], 'ninety_nine'=>['higher',9,0]
}
registry.ids.each do |id|
  game = registry.build(id)
  policy = game.tournament_small_point_policy(options: {})
  if expected.key?(id)
    assert_equal(expected.fetch(id), policy.values_at(:order, :winner, :loser), id)
  else
    assert_equal(nil, policy, id)
    assert_equal({scores: nil, order: 'higher'}, game.tournament_selected_small_scores(nil, options: {}), id)
  end
end
assert_equal(['higher',21,0], registry.build('audio_ball').tournament_small_point_policy(options: {'sets_to_win'=>3}).values_at(:order,:winner,:loser))
assert_equal(['higher',11,0], registry.build('axel_pong').tournament_small_point_policy(options: {'target'=>'unlimited'}).values_at(:order,:winner,:loser))
assert_equal(['higher',47,0], registry.build('axel_pong').tournament_small_point_policy(options: {'target'=>'custom','custom_target'=>47}).values_at(:order,:winner,:loser))
assert_equal(['lower',0,500], registry.build('rummy').tournament_small_point_policy(options: {'elimination'=>true}).values_at(:order,:winner,:loser))

# Existing hook exports stay valid under v5. New policy is opt-in, including
# games added later: no allowlist in the result reader or standings.
game = registry.build('tic_tac_toe')
session = {'__players'=>%w[Ala Bartek], 'options'=>{}}
repository = GameRoomSimulation::Repository.new(%w[Ala Bartek])
events = %w[1,1 1,2 2,1 2,2 3,1].each_with_index.map do |value,index|
  {'id'=>index+1, 'actor'=>index.even? ? 'Ala' : 'Bartek', 'action'=>'place', 'value'=>value}
end
replay = game.replay(session, events, repository)
people = %w[Ala Bartek].map { |name| {'username'=>name,'account'=>name.downcase} }
args = {game: game,replay: replay,players: people,options: {},event_count: events.size}
game.define_singleton_method(:tournament_export_scores) { |_r, options:| {'Ala'=>10,'Bartek'=>3} }
old = GameRoomTournaments::GameResult.from_replay(**args,result_policy: GameRoomTournaments::GameResult::RANKING_RESULT_POLICY)
fresh = GameRoomTournaments::GameResult.from_replay(**args,result_policy: GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
assert_equal({'ala'=>10,'bartek'=>3}, old['scores'])
assert_equal(nil, fresh['scores'])
assert(!fresh.key?('score_order'), 'Disabled games must not expose score direction')
game.define_singleton_method(:tournament_small_point_policy) { |options:| tournament_target_small_points(100,order:'lower') }
game.define_singleton_method(:participant_scores) { |_r| {'Ala'=>2,'Bartek'=>6} }
fresh = GameRoomTournaments::GameResult.from_replay(**args,result_policy: GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
assert_equal({'ala'=>2,'bartek'=>6}, fresh['scores'])
assert_equal('lower', fresh['score_order'])
game.define_singleton_method(:participant_scores) { |_r| nil }
assert_raises(GameRoomGames::Base::Tournaments::InvalidResult) do
  GameRoomTournaments::GameResult.from_replay(**args,result_policy: GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
end
puts 'PASS opt-in policies, targets, directions, disabled games and historical result export'

# A game's numeric finishing order is distinct from exporting small points.
# This future game uses penalties but deliberately does not opt into totals.
names=%w[Ala Bartek Celina Dorota]
ranked=Class.new(GameRoomGames::TicTacToe) do
  def tournament_ranking_scores(replay, options:)
    {scores: replay.state[:ranking], order:'lower'}
  end
end.new
replay=GameRoomGames::Replay.new(players:names,state:{ranking:names.zip([0,4,9,9]).to_h},
  winner:'Ala',draw:false,accepted_events:[])
replay.define_singleton_method(:finished?) { true }
people=names.map { |name| {'username'=>name,'account'=>name.downcase} }
summary=GameRoomTournaments::GameResult.from_replay(game:ranked,replay:replay,players:people,options:{},
  event_count:0,result_policy:GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
assert_equal(nil,summary['scores'])
assert(!summary.key?('score_order'),'Ranking-only numbers leaked their small-point policy')
assert_equal([['ala'],['bartek'],%w[celina dorota]],summary['places'])
removed=GameRoomTournaments::GameResult.with_eliminations(summary,[['bartek']])
assert_equal([['ala'],%w[celina dorota],['bartek']],removed['places'])
assert_equal(nil,removed['scores'])
puts 'PASS disabled numeric export retains game-owned penalty places and shared places after automatic elimination'
