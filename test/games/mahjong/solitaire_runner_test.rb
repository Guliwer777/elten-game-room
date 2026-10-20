require_relative '../../support/session_runner'
require_relative '../../../games/mahjong'

harness = NativeRoomHarness.new(game: GameRoomGames::Mahjong.new, users: ['Alice'])
harness.start
runner = runner_for(harness)
begin
  before_deal = harness.replay('Alice')
  step(harness, runner, count: 3)
  dealt = harness.replay('Alice')
  assert(dealt.state[:phase] == :playing, 'Shared executor did not commit the initial deal')
  assert(harness.events('Alice').length == 1, 'Automatic deal was duplicated')
  seed = JSON.parse(harness.events('Alice').first.fetch('value')).fetch('r')
  solution = GameRoomMahjong::Solitaire.deal(seed: seed).solution
  solution.each do |first, second|
    current = harness.replay('Alice')
    selection = {'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-pairs:#{current.state[:turn]}", 'answer'=>"#{first}:#{second}"}
    harness.as('Alice') do
      status, = runner.submit(session: harness.session, replay: current, selection: selection, actor: 'Alice')
      assert(status == :ok, 'Shared executor rejected a legal matching pair')
    end
    step(harness, runner, count: 2)
  end
  finished = harness.replay('Alice')
  assert(finished.finished? && finished.winner == 'Alice', 'Executor did not finish the solitaire game')
  assert(harness.events('Alice').length == 73, 'Executor lost or duplicated a persisted pair')
  assert(harness.game.participant_scores(finished)['Alice'] == 72, 'Final pair count was not available to shared scoring')
  assert(harness.transports['Alice'].room_snapshot(harness.table)[:table]['status'] == 'waiting', 'Finished solitaire did not release active-game status')
  begin
    harness.as('Alice') do
      runner.submit(session: harness.session, replay: before_deal,
        selection: {'kind'=>'command', 'action'=>'deal', 'turn'=>0}, actor: 'Alice')
    end
    raise 'An obsolete pre-deal screen was accepted'
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
assert(harness.transports['Alice'].instance_variable_get(:@session_feeds).empty?, 'Closing solitaire leaked a live-session feed')
puts 'PASS solitaire shared executor: automatic deal, 72 human pair commits, finished room status, stale-view rejection and clean close through native LiveSessions fixture'
