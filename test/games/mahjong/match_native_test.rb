require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../support/mahjong_match'
include GameRoomTest::Assertions
include MahjongMatchFixture

NativeOptionTest.native_method(ListBox, :update, 'src/ui/controls/list_box.rb')
NativeOptionTest.native_method(Button, :press, 'src/ui/controls/button.rb')
fixture = match_between_fixture
repo, session, events = fixture.values_at(:repo, :session, :events)
%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  game = MahjongTableGameTest::Game.new
  dealt = game.replay(session, events.first(1), repo)
  surface = GameSurfaces.build(game.surface_spec(dealt, viewer: 'Alice'))
  selected = []
  surface.on_action { |action| selected << action.to_h }
  surface.fields_for_parts(['hand']).find { |field| field.is_a?(ListBox) }.trigger(:select, 0)
  assert(selected.first['question_id'].end_with?(':h1'))
  assert_equal(:ok, game.action_for(selected.first, dealt, 'Alice', context: fixture[:context]).first)

  before = game.replay(session, events, repo)
  surface = GameSurfaces.build(game.surface_spec(before, viewer: 'Alice'))
  choices = []
  surface.on_action { |action| choices << action.to_h }
  button = surface.fields_for_parts(['match_ready']).find { |field| field.is_a?(Button) }
  assert(button)
  button.press
  ready = choices.first
  assert_equal('ready', ready['action'])
  assert_equal(1, ready['hand'])
  bob_choice = game.legal_actions(before, 'Bob').first
  status, plan = game.action_for(bob_choice, before, 'Bob', context: fixture[:context])
  assert_equal(:ok, status)
  bob_event = table_event(events.length + 1, plan.events.first, actor: 'Bob')
  after = game.incremental_replay(before, session, [bob_event], repo)
  assert(game.concurrent_session_input?(before, after, ready))
  status, plan = game.action_for(ready, after, 'Alice', context: fixture[:context])
  assert_equal(:ok, status)
  alice_event = table_event(events.length + 2, plan.events.first, actor: 'Alice')
  voted = game.incremental_replay(after, session, [alice_event], repo)
  assert_equal([0, 1], voted.state[:ready_seats])
  assert(game.surface_spec(voted, viewer: 'Alice').parts.none? { |part| part.id == 'match_ready' })
  assert(game.surface_spec(voted, viewer: 'Observer').parts.none? { |part| part.id == 'match_ready' })
end
puts 'PASS full-match native EN/PL/CS/ES/RU: hand-scoped controls, next-hand readiness button, concurrent votes, voted-player/spectator restrictions'
