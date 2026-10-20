require_relative '../../support/assertions'
require_relative '../../support/mahjong_table_game'
require_relative '../../support/elten_array_shuffle'
include GameRoomTest::Assertions
include MahjongTableGameTest

[['mcr', 4], ['riichi', 4], ['riichi', 3], ['hong_kong', 4]].each do |variant, seats|
  game = MahjongTableGameTest::Game.new
  repository = MahjongTableGameTest::Repository.new
  players = %w[Alice Bob Carol Dave].first(seats)
  session = {'id'=>45, 'players'=>players, 'options'=>JSON.generate('variant'=>variant, 'seats'=>seats)}
  random = MahjongTableGameTest::RandomSource.new
  context = GameRoomGames::ActionContext.new(session_id: 45, random_source: random)
  initial = game.replay(session, [], repository)
  assert_equal(:awaiting_deal, initial.state[:phase])
  assert(game.surface_spec(initial, viewer: 'Observer').read_only)
  selection = game.automatic_action(initial, 'Alice', context: context)
  assert_equal(nil, game.automatic_action(initial, 'Bob', context: context))
  assert_equal(:not_your_turn, game.action_for(selection, initial, 'Observer', context: context).first)
  status, plan = game.action_for(selection, initial, 'Alice', context: context)
  assert_equal(:ok, status)
  events = [table_event(1, plan.events.first, actor: 'Alice')]
  current = game.incremental_replay(initial, session, events, repository)
  assert_equal(:playing, current.state[:phase])
  assert_equal(1, random.calls)
  opening_round = current.state[:round]
  discard = opening_round.legal_actions(seat: 0).find { |action| action[:type] == :discard }
  reactions = opening_round.action(**discard)
  before = current.dup
  before.state = current.state.merge(round: reactions).freeze
  response_seat = reactions.window.pending.first
  responded = reactions.action(seat: response_seat, type: :claim, choice: [:pass], generation: reactions.flow.generation)
  after = before.dup
  after.state = before.state.merge(round: responded).freeze
  other_seat = responded.window.pending.first
  pending_selection = GameRoomMahjong::TableEvents.to_selection(responded.legal_actions(seat: other_seat).first)
  assert(game.concurrent_session_input?(before, after, pending_selection))
  assert_equal(false, game.concurrent_session_input?(before, after, pending_selection.merge('question_id'=>'mahjong-claim:999')))
  # Cold reconstruction of an equivalent reaction state must work as well;
  # object identity is not a protocol boundary.
  copied = responded.flow
  rebuilt_flow = GameRoomMahjong::TileFlow.new(**%i[hands wall seat phase generation discards melds reserve flowers replacement_source replacement_draws last_draw draw_origin discard_history].to_h { |key| [key, copied.public_send(key)] })
  reconstructed = after.dup
  reconstructed.state = after.state.merge(round: responded.with(flow: rebuilt_flow)).freeze
  assert(game.concurrent_session_input?(before, reconstructed, pending_selection))
  assert_equal(nil, game.incremental_replay(current, session.merge('id'=>46), [], repository))
  assert_equal(nil, game.incremental_replay(current, session, [], MahjongTableGameTest::Repository.new))
  assert_equal(nil, game.incremental_replay(current, session.merge('players'=>players.reverse), [], repository))
  other_context = GameRoomGames::ActionContext.new(session_id: 46, random_source: random)
  first_actor = game.active_actors(current).first
  choice = game.table_bot_selection(current, first_actor)
  assert_equal(:stale, game.action_for(choice, current, first_actor, context: other_context).first)
  assert_equal(:invalid, game.action_for(choice, current, 'Bob', context: context).first)
  step_count = 0
  until current.finished?
    actor = game.active_actors(current).first
    selection = game.table_bot_selection(current, actor)
    assert(game.legal_actions(current, actor).include?(selection))
    status, plan = game.action_for(selection, current, actor, context: context)
    assert_equal(:ok, status)
    command = plan.events.first
    assert(command.value.bytesize <= 64)
    # A spectator may not smuggle an otherwise valid event into accepted history.
    forged = table_event(events.length + 1, command, actor: 'Observer')
    ignored = game.incremental_replay(current, session, [forged], repository)
    assert_equal(current.accepted_events.length, ignored.accepted_events.length)
    assert_equal(round_snapshot(current.state[:round]), round_snapshot(ignored.state[:round]))
    event = table_event(events.length + 1, command, actor: actor)
    events << event
    previous = current
    snapshot = round_snapshot(previous.state[:round])
    current = game.incremental_replay(current, session, [event], repository)
    if %w[draw replacement].include?(selection['action'])
      assert_equal(game.send(:mahjong_table_move_text, {type: :draw}, actor), current.history.last.text,
        'Public draw history must not reveal a private tile face')
    end
    assert_equal(snapshot, round_snapshot(previous.state[:round]))
    assert_equal(events.length, current.accepted_events.length)
    step_count += 1
    raise 'Session replay did not finish' if step_count > 600
  end
  fresh = MahjongTableGameTest::Game.new.replay(session, events, repository)
  assert_equal(round_snapshot(current.state[:round]), round_snapshot(fresh.state[:round]))
  assert_equal(current.winner, fresh.winner)
  assert_equal(current.draw, fresh.draw)
  assert_equal(0, game.participant_scores(current).values.sum)
  assert_equal(1, random.calls, 'Replay and bot planning may not generate a new deal')
  assert_equal([], game.active_actors(current))
  assert_equal([], game.legal_actions(current, 'Alice'))
  assert_equal(current.accepted_events.length, game.incremental_replay(current, session, events, repository).accepted_events.length)
end
puts 'PASS internal mahjong table session replay: MCR/Riichi complete hands, compact moves, owned actors, session guards, immutable incremental/cold replay and finished scores'
