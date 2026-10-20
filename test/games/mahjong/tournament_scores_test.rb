require_relative '../../support/assertions'
require_relative '../../../games/mahjong'
include GameRoomTest::Assertions
game=GameRoomGames::Mahjong.new
players=%w[Alice Bob Carol Dave]
match=GameRoomMahjong::MatchState.new(variant:'mcr',points:[30,10,-10,-30],initial_points:[0,0,0,0],rotations:16)
replay=GameRoomGames::Replay.new(players:players,winner:'Alice',draw:false,
  state:{profile:{'variant'=>'mcr'},phase: :finished,match:match})
assert_equal(players.zip([30,10,-10,-30]).to_h,game.tournament_ranking_scores(replay,options:game.normalize_options('variant'=>'mcr'))[:scores])
puts 'PASS Mahjong exports every seat score for multiplayer tournament standings, not just the winning seat'
