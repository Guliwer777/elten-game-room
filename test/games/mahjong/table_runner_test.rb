require_relative '../../support/session_runner'
require_relative '../../../games/mahjong'

game = GameRoomGames::Mahjong.new
h = NativeRoomHarness.new(game: game, users: ['Alice'], bots: 3,
  options: game.normalize_options('variant'=>'mcr', 'mcr_winds'=>'0', 'bot_delay'=>0))
h.start
runner = runner_for(h)
runner.instance_variable_get(:@context_template).random_source = GameRoomRandom::SeededSource.new(137)
tick = 0.0
runner.instance_variable_get(:@turn).instance_variable_set(:@clock, -> { tick })
begin
  original = h.replay('Alice')
  600.times do
    tick += 2
    step(h, runner)
    current = h.replay('Alice')
    break if current.finished?
    selected = game.table_bot_selection(current, 'Alice')
    if selected
      h.as('Alice') do
        status, = runner.submit(session: h.session, replay: current, selection: selected, actor: 'Alice')
        assert(status == :ok, 'Shared executor rejected a legal Mahjong human action')
      end
    end
  end
  current = h.replay('Alice')
  assert(current.finished?, 'Shared executor failed to finish the Mahjong hand')
  events = h.events('Alice')
  assert(events.count { |event| event['action'] == 'mahjong_deal' } == 1, 'Initial deal was duplicated')
  assert(events.any? { |event| event['actor'].to_s.start_with?('bot:') }, 'No bot action passed through the executor')
  assert(events.length == current.accepted_events.length, 'Executor persisted a rejected move')
  assert(game.participant_scores(current).values.sum == 0, 'Final Mahjong payments do not balance')
  step(h, runner) # Final human action is published before the next executor refresh.
  assert(h.transports['Alice'].room_snapshot(h.table)[:table]['status'] == 'waiting', 'Finished Mahjong hand left the room active')
  begin
    h.as('Alice') { runner.submit(session: h.session, replay: original, selection: {'kind'=>'command', 'action'=>'deal'}, actor: 'Alice') }
    raise 'An obsolete Mahjong screen was accepted'
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
assert(h.transports['Alice'].instance_variable_get(:@session_feeds).empty?, 'Closing Mahjong leaked its session feed')
puts 'PASS Mahjong shared executor: automatic deal, one human/three bots, complete hand, accepted compact moves, balanced results, stale screen rejection and feed cleanup'
