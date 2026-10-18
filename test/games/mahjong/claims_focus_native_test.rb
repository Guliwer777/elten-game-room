require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../support/mahjong_added_kong'
include GameRoomTest::Assertions
include MahjongRoundFixture
include MahjongAddedKongFixture

# Construct native controls without running the separate options-dialog driver.
def loop_update(*); end

players = %w[Alice Bob Carol Dave]
%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  %w[hong_kong riichi mcr].each do |variant|
    game = EltenGameRoom::GAME_REGISTRY.build('mahjong')
    flow = ready_flow('123456m23455p67s', '8s', self_draw: true)
    round = GameRoomMahjong::TableRound.new(flow: flow, variant: variant, dealer: 1)
    round = round.action(seat: 0, type: :discard, tile: flow.hands[0].first, generation: flow.generation)
    state = {session_id: 77, profile: {'variant'=>variant}, round: round, phase: :playing, hand_number: 1, match: nil}
    replay = GameRoomGames::Replay.new(players: players, state: state, accepted_events: [], history: [])
    view = game.game_view_spec(replay, 'Bob')
    assert_equal(%w[status claims hand], view.surface.parts.first(3).map(&:id))
    assert_equal('claims', view.decision_focus_part)
    claims = view.surface.parts[1].surface
    status = view.surface.parts[0].surface.value
    assert(claims.prompt.start_with?(status), 'Response focus must identify the current tile before the choices')
    layout = GameRoomLayout::Screen.new(view_spec: view)
    response = layout.surface.fields_for_parts(['claims']).first
    decision = game.game_shortcuts(replay, 'Bob').find { |shortcut| shortcut.key == 'd' }
    assert(decision && decision.kind == :announcement)
    assert_equal(GameRoomMahjong::TileLabels.label(round.flow.discards.last.last), decision.message)
    assert(decision.label != 'read the tile awaiting your response') unless language == 'en'
    spoken = []
    screen = GameScreen.allocate
    screen.define_singleton_method(:speak) { |text, **_| spoken << text }
    selected = response.index
    assert_equal(nil, screen.send(:activate_game_shortcut, decision, layout.surface, replay: replay))
    assert_equal([decision.message], spoken)
    assert_equal(selected, response.index)
    assert_equal(response, layout.form.fields[layout.form.index])
    assert(game.game_shortcuts(replay, 'Observer').none? { |shortcut| shortcut.key == 'd' })
    assert_equal(response, layout.form.fields[layout.form.index])
    assert(layout.decision_focus_changed?, 'Opening a pending decision failed to focus responses')
    actions = []
    layout.surface.on_action { |action| actions << action }
    assert_equal([], actions, 'Focusing must never submit Pass automatically')
    response.index = 0
    response.trigger(:select, 0)
    assert_equal(1, actions.length)
    assert_equal(claims.id, actions.first.to_h.fetch('question_id'))
    spectator = game.game_view_spec(replay, 'Observer')
    assert_equal(nil, spectator.decision_focus_key)
    assert(spectator.surface.parts.none? { |part| part.id == 'claims' }, 'Spectator received an answer control')
    answered = round.action(seat: 1, type: :claim, choice: [:pass], generation: round.flow.generation)
    after = GameRoomGames::Replay.new(players: players, state: state.merge(round: answered), accepted_events: [], history: [])
    assert(game.game_shortcuts(after, 'Bob').none? { |shortcut| shortcut.key == 'd' })
    assert_equal(nil, game.game_view_spec(after, 'Bob').decision_focus_key)
    answered.window.pending.dup.each do |seat|
      answered = answered.action(seat: seat, type: :claim, choice: [:pass], generation: answered.flow.generation)
    end
    assert_equal(:draw, answered.flow.phase)
    assert_equal(1, answered.flow.seat)
    draw_replay = GameRoomGames::Replay.new(players: players, state: state.merge(round: answered), accepted_events: [], history: [])
    draw_view = game.game_view_spec(draw_replay, 'Bob')
    assert_equal(%w[status commands hand], draw_view.surface.parts.first(3).map(&:id))
    layout.update(view_spec: draw_view, history_items: [], user_items: [], users_header: '')
    assert_equal(layout.surface.fields_for_parts(['commands']).first, layout.form.fields[layout.form.index])
    drawn = answered.action(seat: 1, type: :draw, generation: answered.flow.generation)
    drawn_replay = GameRoomGames::Replay.new(players: players, state: state.merge(round: drawn), accepted_events: [], history: [])
    drawn_view = game.game_view_spec(drawn_replay, 'Bob')
    layout.update(view_spec: drawn_view, history_items: [], user_items: [], users_header: '')
    hand_control = layout.surface.fields_for_parts(['hand']).first
    assert_equal(hand_control, layout.form.fields[layout.form.index])
    hand_spec = drawn_view.surface.parts.find { |part| part.id == 'hand' }.surface
    assert_equal(drawn.flow.last_draw.to_s, hand_spec.options.fetch(hand_control.index).value)
    hand_control.index = 0
    layout.update(view_spec: game.game_view_spec(drawn_replay, 'Bob'), history_items: [], user_items: [], users_header: '')
    assert_equal(0, layout.surface.fields_for_parts(['hand']).first.index, 'Refreshing interrupted manual browsing after the draw')
    assert_equal([], actions.drop(1), 'Focus changes submitted another action')
    kong_round = GameRoomMahjong::TableRound.new(flow: added_kong_flow, variant: variant, dealer: 0)
    kong_round = kong_round.action(**kong_round.legal_actions(seat: 1).find { |action| action[:type] == :added_kong })
    kong_replay = GameRoomGames::Replay.new(players: players, state: state.merge(round: kong_round), accepted_events: [], history: [])
    kong_decision = game.game_shortcuts(kong_replay, 'Alice').find { |shortcut| shortcut.key == 'd' }
    assert_equal(GameRoomMahjong::TileLabels.label(kong_round.added_kong_kind * 4), kong_decision.message)
  end
end
puts 'PASS Mahjong response focus EN/PL/CS/ES/RU and HK/Riichi/MCR: status-response-hand, spoken tile context, no automatic answer, pending participants only'
