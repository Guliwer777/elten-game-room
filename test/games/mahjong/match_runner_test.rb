require_relative '../../support/session_runner'
require_relative '../../../games/mahjong'

game = GameRoomGames::Mahjong.new
h = NativeRoomHarness.new(game: game, users: ['Alice'], bots: 3,
  options: game.normalize_options('variant'=>'mcr', 'mcr_winds'=>'4', 'bot_delay'=>0))
h.start
assert(h.broker.cores.values.first.stack_entries == 32_768, 'Mahjong table did not request its long-match history budget')
runner = runner_for(h)
runner.instance_variable_get(:@context_template).random_source = GameRoomRandom::SeededSource.new(137)
tick = 0.0
runner.instance_variable_get(:@turn).instance_variable_set(:@clock, -> { tick })
begin
  old_replay = old_selection = nil
  600.times do
    tick += 2
    step(h, runner)
    current = h.replay('Alice')
    break if current.state[:phase] == :between_hands
    selected = game.table_bot_selection(current, 'Alice')
    if selected
      old_replay, old_selection = current, selected
      h.as('Alice') do
        status, = runner.submit(session: h.session, replay: current, selection: selected, actor: 'Alice')
        assert(status == :ok, 'Shared executor rejected a scoped match move')
      end
    end
  end
  between = h.replay('Alice')
  assert(between.state[:phase] == :between_hands && !between.finished?, 'First hand incorrectly finished the whole match')
  assert(h.transports['Alice'].room_snapshot(h.table)[:table]['status'] == 'playing', 'Between-hand match released its active room')
  6.times { tick += 2; step(h, runner) }
  waiting = h.replay('Alice')
  assert(waiting.state[:phase] == :between_hands, 'The match started another hand without the human ready vote')
  assert(waiting.state[:ready_seats].sort == [1, 2, 3], 'Ordinary shared bot strategy failed to confirm readiness')
  selected = game.legal_actions(waiting, 'Alice').first
  assert(selected['action'] == 'ready' && selected['hand'] == 1, 'Human next-hand choice missing')
  h.as('Alice') do
    status, = runner.submit(session: h.session, replay: waiting, selection: selected, actor: 'Alice')
    assert(status == :ok, 'Shared executor rejected readiness')
  end
  3.times { tick += 2; step(h, runner) }
  next_hand = h.replay('Alice')
  assert(next_hand.state[:hand_number] == 2 && next_hand.state[:phase] == :playing, 'Shared automatic deal did not start the second hand')
  assert(next_hand.state[:round].dealer == 1, 'Dealer did not move for the next MCR hand')
  assert(h.events('Alice').count { |event| event['action'] == 'mahjong_deal' } == 2, 'Next deal was lost or duplicated')
  begin
    h.as('Alice') { runner.submit(session: h.session, replay: old_replay, selection: old_selection, actor: 'Alice') }
    raise 'A screen from the previous hand was accepted'
  rescue GameRoomSessionRunner::StaleView
  end
ensure
  primary = $!
  begin
    runner.close
  rescue StandardError
    raise unless primary
  end
end
assert(h.transports['Alice'].instance_variable_get(:@session_feeds).empty?, 'Closing the match leaked a session feed')
puts 'PASS full-match shared executor: scoped human/bot moves, room stays active between hands, all bots ready, human confirmation, one next deal and previous-hand stale rejection'
