# encoding: UTF-8
require_relative 'tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
directory, now = ARGV
program = TournamentEntryContextTest::Program.new(directory)
sandbox = File.join(directory, 'tournament-local-test-' + Digest::SHA256.hexdigest(F::OWNER.downcase))
plans = File.join(sandbox, 'plans')
state = JSON.parse(File.read(File.join(plans, 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')))
record = state.fetch('records').values.first
fixture = {program: program, plans: plans, sandbox: sandbox, now: Integer(now)}
begin
  F.with_execution(fixture, 'Anna') do |execution|
    F.select_execution(execution, record, history: true)
    read = execution.local_game(action: :local_game_status)
    assert_equal(:confirmed, read[:state])
    assert_equal('awaiting_deal', read[:status]['phase'])
    assert_equal(0, read[:status]['event_count'])
    assert_equal(state['executions'].values.find { |r| r['start'] }['start']['session_id'], read[:status]['session_id'])
  end
  puts 'PASS cold Start and real Spades replay in fresh process'
ensure
  program.finalize
  program.class.app_runtime.close
end
