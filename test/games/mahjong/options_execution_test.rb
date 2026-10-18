require_relative '../../support/assertions'
require_relative '../../support/mahjong_options_game'
require_relative '../../support/mahjong_table_game'
require_relative '../../support/mahjong_game'
require_relative '../../support/elten_array_shuffle'
include GameRoomTest::Assertions

class ConfiguredMahjongTable < MahjongTableGameTest::Game
  include GameRoomGames::MahjongOptions
end
class ConfiguredMahjongSolitaire < MahjongGameTest::Game
  include GameRoomGames::MahjongOptions
end

[['hong_kong', 4, 'hong_kong_winds'], ['riichi', 4, 'riichi_winds'],
 ['riichi', 3, 'riichi_winds'], ['mcr', 4, 'mcr_winds']].each do |variant, seats, length_key|
  game = ConfiguredMahjongTable.new
  definition = game.option_definitions.find { |entry| entry.key == length_key }
  definition.choices.each do |choice|
    options = game.normalize_options('variant'=>variant, 'riichi_seats'=>seats.to_s, length_key=>choice.value)
    repo = MahjongTableGameTest::Repository.new
    session = {'id'=>45, 'players'=>%w[Alice Bob Carol Dave].first(seats), 'options'=>JSON.generate(options)}
    context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongTableGameTest::RandomSource.new)
    initial = game.replay(session, [], repo)
    status, plan = game.action_for(game.automatic_action(initial, 'Alice', context: context), initial, 'Alice', context: context)
    assert_equal(:ok, status)
    event = {'id'=>1, 'actor'=>'Alice', 'action'=>plan.events.first.action, 'value'=>plan.events.first.value}
    current = game.replay(session, [event], repo)
    assert_equal(:playing, current.state[:phase])
    assert_equal(seats, current.state[:round].flow.hands.length)
    if choice.value == '0'
      assert_equal(nil, current.state[:match])
    else
      assert_equal(choice.value.to_i, current.state[:match].winds)
    end
  end
end
%w[flat terraces].each do |layout|
  game = ConfiguredMahjongSolitaire.new
  options = game.normalize_options('variant'=>'solitaire', 'layout'=>layout)
  repo = MahjongGameTest::Repository.new
  session = {'id'=>45, 'players'=>['Alice'], 'options'=>JSON.generate(options)}
  context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongGameTest::RandomSource.new)
  initial = game.replay(session, [], repo)
  status, plan = game.action_for(game.automatic_action(initial, 'Alice', context: context), initial, 'Alice', context: context)
  assert_equal(:ok, status)
  event = {'id'=>1, 'actor'=>'Alice', 'action'=>plan.events.first.action, 'value'=>plan.events.first.value}
  current = game.replay(session, [event], repo)
  assert_equal(layout, current.state[:layout])
  assert_equal(144, current.state[:board].remaining.length)
end
puts 'PASS configured Mahjong adapters: every offered length/seat combination and both Solitaire layouts start the selected game'
