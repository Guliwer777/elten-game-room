require_relative '../../support/assertions'
require_relative '../../support/mahjong_table_game'
require_relative '../../support/mahjong_game'
require_relative '../../support/elten_array_shuffle'
require_relative '../../../games/mahjong'
include GameRoomTest::Assertions

game = GameRoomGames::Mahjong.new
[['solitaire', 1], ['hong_kong', 4], ['riichi', 4], ['riichi', 3], ['mcr', 4]].each do |variant, seats|
  options = game.normalize_options('variant'=>variant, 'riichi_seats'=>seats.to_s)
  repo = MahjongTableGameTest::Repository.new
  session = {'id'=>45, 'players'=>%w[Alice Bob Carol Dave].first(seats), 'options'=>JSON.generate(options)}
  context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongTableGameTest::RandomSource.new)
  initial = game.replay(session, [], repo)
  selection = game.automatic_action(initial, 'Alice', context: context)
  status, plan = game.action_for(selection, initial, 'Alice', context: context)
  assert_equal(:ok, status)
  event = {'id'=>1, 'actor'=>'Alice', 'action'=>plan.events.first.action, 'value'=>plan.events.first.value}
  current = game.incremental_replay(initial, session, [event], repo)
  assert_equal(:playing, current.state[:phase])
  assert(game.surface_spec(current, viewer: 'Alice'))
  assert(game.game_view_spec(current, 'Alice').surface)
  assert(game.game_view_spec(current, 'Observer').surface)
  assert_equal(seats, game.participant_scores(current).length)
  assert(!game.legal_actions(current, 'Alice').empty?)
  cold = GameRoomGames::Mahjong.new.replay(session, [event], repo)
  assert_equal(current.accepted_events, cold.accepted_events)
  assert_equal(current.history.map(&:text), cold.history.map(&:text))
  if variant == 'solitaire'
    assert_equal(current.state[:board].tiles, cold.state[:board].tiles)
    assert_equal(current.state[:board].remaining, cold.state[:board].remaining)
  else
    assert_equal(current.state[:round].flow.hands, cold.state[:round].flow.hands)
  end
  assert_equal(nil, game.table_bot_selection(current, 'Observer'))
end
assert(game.build_session_game.is_a?(GameRoomGames::Mahjong))
assert(game.build_presentation_game.is_a?(GameRoomGames::Mahjong))
puts 'PASS single Mahjong facade: all variants, ordinary automatic deal/action/replay, surfaces, scores, observer and independent instances'
