require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../support/mahjong_added_kong'
require_relative '../../../games/mahjong_support/table_events'
require_relative '../../../games/mahjong_support/table_presentation'
include GameRoomTest::Assertions
include MahjongRoundFixture
include MahjongAddedKongFixture

class MahjongTableNativeGame < GameRoomGames::Base
  include GameRoomGames::MahjongTablePresentation
end
NativeOptionTest.native_method(ListBox, :update, 'src/ui/controls/list_box.rb')
NativeOptionTest.native_method(Button, :press, 'src/ui/controls/button.rb')
players = %w[Alice Bob Carol Dave]
%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  game = MahjongTableNativeGame.new
  flow = ready_flow('123456m23455p67s', '8s', self_draw: true)
  round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'riichi', dealer: 1)
  spec = game.table_surface_spec(round, players: players, viewer: 'Alice')
  if spec.parts.any? { |part| part.id == 'commands' }
    assert(spec.parts.index { |part| part.id == 'commands' } < spec.parts.index { |part| part.id == 'hand' })
  end
  own = spec.parts.find { |part| part.id == 'hand' }.surface
  assert_equal(flow.hands[0].map(&:to_s).sort, own.options.map(&:value).sort)
  assert(own.submit_on_select)
  surface = GameSurfaces.build(spec)
  actions = []
  surface.on_action { |action| actions << action }
  list = surface.fields_for_parts(['hand']).find { |field| field.is_a?(ListBox) }
  list.options.each { |text| assert(text.encoding == Encoding::UTF_8 && text.valid_encoding?) }
  list.index = 0
  list.trigger(:move, 0)
  assert_equal([], actions)
  list.trigger(:select, 0)
  assert_equal(1, actions.length)
  selection = actions.first.to_h
  assert_equal("mahjong-discard:#{flow.generation}", selection.fetch('question_id'))
  tile = Integer(selection.fetch('answer'))
  next_round = round.action(seat: 0, type: :discard, tile: tile, generation: flow.generation)
  assert_equal(:reactions, next_round.flow.phase)
  assert_raises(ArgumentError) { next_round.action(seat: 0, type: :discard, tile: tile, generation: flow.generation) }

  waiting = game.table_surface_spec(next_round, players: players, viewer: 'Bob')
  hand = waiting.parts.find { |part| part.id == 'hand' }.surface
  assert(hand.read_only)
  assert_equal(next_round.flow.hands[1].map(&:to_s).sort, hand.options.map(&:value).sort)
  claims = waiting.parts.find { |part| part.id == 'claims' }.surface
  assert_equal(next_round.window.offers[1].map { |choice| choice.join(':') }, claims.options.map(&:value))
  spectator_spec = game.table_surface_spec(next_round, players: players, viewer: 'Observer')
  assert(spectator_spec.parts.none? { |part| %w[hand claims commands].include?(part.id) })
  spectator = GameSurfaces.build(spectator_spec)
  assert(spectator.fields.none? { |field| field.is_a?(ListBox) || field.is_a?(Button) })
  finished = round.action(seat: 0, type: :win, generation: flow.generation)
  final_spec = game.table_surface_spec(finished, players: players, viewer: 'Observer')
  assert_equal(%w[status winning_hand value payments wall], final_spec.parts.map(&:id))
  payments = final_spec.parts.find { |part| part.id == 'payments' }.surface.value
  players.each { |player| assert(payments.include?(player)) }
  assert(final_spec.parts.none? { |part| %w[hand claims commands].include?(part.id) })
  mcr_flow = ready_flow('123456789m1115z', '5z', self_draw: true)
  mcr_round = GameRoomMahjong::TableRound.new(flow: mcr_flow, variant: 'mcr', dealer: 0)
  mcr_finished = mcr_round.action(seat: 0, type: :win, generation: mcr_flow.generation)
  mcr_spec = game.table_surface_spec(mcr_finished, players: players, viewer: 'Observer')
  mcr_value = mcr_spec.parts.find { |part| part.id == 'value' }.surface.value
  assert(mcr_value.include?('31'))
  assert(mcr_value.include?('0'))
  assert(mcr_value.encoding == Encoding::UTF_8 && mcr_value.valid_encoding?)
  assert(!mcr_value.include?('flower points') || language == 'en')
  mcr_surface = GameSurfaces.build(mcr_spec)
  assert(mcr_surface.fields.none? { |field| field.is_a?(ListBox) || field.is_a?(Button) })
  restricted = round.with(blocked_discards: [GameRoomMahjong::Tiles.kind(flow.hands[0].first)])
  restricted_spec = game.table_surface_spec(restricted, players: players, viewer: 'Alice')
  full_hand = restricted_spec.parts.find { |part| part.id == 'all_tiles' }.surface
  permitted = restricted_spec.parts.find { |part| part.id == 'hand' }.surface
  assert(full_hand.read_only)
  assert_equal(flow.hands[0].map(&:to_s).sort, full_hand.options.map(&:value).sort)
  assert_equal(restricted.legal_discards.map(&:to_s).sort, permitted.options.map(&:value).sort)

  kong_base = ready_flow('1111m234m567p789s', '5z', self_draw: true)
  kong_flow = GameRoomMahjong::TileFlow.new(hands: kong_base.hands, wall: kong_base.wall.drop(1),
    reserve: kong_base.wall.first(1), seat: 0, phase: :discard, last_draw: kong_base.last_draw, draw_origin: :normal)
  kong_round = GameRoomMahjong::TableRound.new(flow: kong_flow, variant: 'riichi', dealer: 1)
  kong_surface = GameSurfaces.build(game.table_surface_spec(kong_round, players: players, viewer: 'Alice'))
  kong_actions = []
  kong_surface.on_action { |action| kong_actions << action }
  kong_list = kong_surface.fields_for_parts(['concealed_kongs']).find { |field| field.is_a?(ListBox) }
  kong_list.trigger(:select, 0)
  assert_equal("mahjong-kong:#{kong_flow.generation}", kong_actions.first.to_h.fetch('question_id'))
  kong_kind = Integer(kong_actions.first.to_h.fetch('answer'))
  committed = kong_round.action(seat: 0, type: :concealed_kong, tile: kong_kind, generation: kong_flow.generation)
  assert_equal(:replacement, committed.flow.phase)
  added_flow = added_kong_flow
  added_round = GameRoomMahjong::TableRound.new(flow: added_flow, variant: 'mcr', dealer: 0)
  added_surface = GameSurfaces.build(game.table_surface_spec(added_round, players: players, viewer: 'Bob'))
  added_actions = []
  added_surface.on_action { |action| added_actions << action.to_h }
  added_list = added_surface.fields_for_parts(['added_kongs']).find { |field| field.is_a?(ListBox) }
  added_list.trigger(:select, 0)
  selection = added_actions.first
  assert_equal("mahjong-added-kong:#{added_flow.generation}", selection.fetch('question_id'))
  plan = GameRoomMahjong::TableEvents.selection(selection, round: added_round, seat: 1)
  waiting_kong = added_round.action(**plan)
  peer_spec = game.table_surface_spec(waiting_kong, players: players, viewer: 'Alice')
  peer_claims = peer_spec.parts.find { |part| part.id == 'claims' }.surface
  assert(peer_claims.options.map(&:value).include?('win'))
  owner_spec = game.table_surface_spec(waiting_kong, players: players, viewer: 'Bob')
  assert(owner_spec.parts.find { |part| part.id == 'hand' }.surface.read_only)
  assert(owner_spec.parts.none? { |part| %w[claims commands added_kongs concealed_kongs].include?(part.id) })
  observer = game.table_surface_spec(waiting_kong, players: players, viewer: 'Observer')
  assert(observer.parts.none? { |part| %w[hand claims commands].include?(part.id) })
  riichi_flow = ready_flow('123m456p789s1112z', '5z', self_draw: true)
  riichi_round = GameRoomMahjong::TableRound.new(flow: riichi_flow, variant: 'riichi', dealer: 0)
  declaration_surface = GameSurfaces.build(game.table_surface_spec(riichi_round, players: players, viewer: 'Alice'))
  declaration_actions = []
  declaration_surface.on_action { |action| declaration_actions << action.to_h }
  declaration_list = declaration_surface.fields_for_parts(['riichi']).find { |field| field.is_a?(ListBox) }
  declaration_list.trigger(:select, 0)
  action = GameRoomMahjong::TableEvents.selection(declaration_actions.first, round: riichi_round, seat: 0)
  assert_equal(:riichi, action[:type])
  declaring = riichi_round.action(**action)
  assert_equal(0, declaring.riichi_state.sticks)
  declaring.window.pending.each do |seat|
    declaring = declaring.action(seat: seat, type: :claim, choice: [:pass], generation: declaring.flow.generation)
  end
  assert_equal(1, declaring.riichi_state.sticks)
  status = game.table_surface_spec(declaring, players: players, viewer: 'Observer').parts.find { |part| part.id == 'riichi_status' }.surface.value
  assert(status.include?('Alice'))
  assert(status.include?('1'))
  assert(status.encoding == Encoding::UTF_8 && status.valid_encoding?)
end
puts 'PASS native mahjong table in EN/PL/CS/ES/RU: own physical tiles, arrow/Enter distinction, discard generation, legal claim list and spectator privacy'
