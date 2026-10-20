require_relative '../../support/session_runner'
require_relative '../../support/mahjong_table_game'

game = MahjongTableGameTest::Game.new
h = NativeRoomHarness.new(game: game, users: %w[Alice Bob], bots: 2,
  options: game.default_options.merge('variant'=>'mcr', 'seats'=>4, 'bot_delay'=>0))
h.start
host = runner_for(h)
guest = runner_for(h, 'Bob')
host.instance_variable_get(:@context_template).random_source = GameRoomRandom::SeededSource.new(137)
tick = 0.0
host.instance_variable_get(:@turn).instance_variable_set(:@clock, -> { tick })
begin
  tick += 2
  step(h, host)
  dealt = h.replay('Alice')
  assert(dealt.state[:phase] == :playing, 'Host failed to deal')
  choice = game.legal_actions(dealt, 'Alice').find { |action| action['question_id'].to_s.start_with?('mahjong-discard:') }
  h.as('Alice') do
    status, = host.submit(session: h.session, replay: dealt, selection: choice, actor: 'Alice')
    assert(status == :ok, 'Host discard was rejected')
  end
  old_guest_view = h.replay('Bob')
  pending = game.legal_actions(old_guest_view, 'Bob').find { |action| action['answer'] == 'pass' }
  assert(pending, 'Guest did not get a claim response')
  initial_count = h.events('Alice').length
  4.times do
    tick += 2
    step(h, host)
  end
  assert(h.events('Alice').length > initial_count, 'Other seats did not respond while the guest was choosing')
  current = h.replay('Bob')
  assert(current.state[:round].window.pending.include?(1), 'Guest response disappeared')
  assert(game.concurrent_session_input?(old_guest_view, current, pending), 'Same-discard response was incorrectly treated as obsolete')
  h.as('Bob') do
    status, = guest.submit(session: h.session, replay: old_guest_view, selection: pending, actor: 'Bob')
    assert(status == :ok, 'Shared executor rejected the pending guest response after bot responses')
  end
  converged = h.replay('Alice')
  assert(converged.state[:round].flow.phase == :draw, 'All responses did not release the next draw')
  assert(h.events('Alice').length == converged.accepted_events.length, 'Concurrent response wrote an invalid event')
  assert(h.replay('Bob').accepted_events.length == converged.accepted_events.length, 'Clients disagree on accepted history')
ensure
  primary = $!
  [guest, host].each do |runner|
    begin
      runner.close
    rescue StandardError
      raise unless primary
    end
  end
end
puts 'PASS Mahjong concurrent shared executor: two native clients, bot replies while guest chooses, preserved legal pending answer and converged accepted history'
