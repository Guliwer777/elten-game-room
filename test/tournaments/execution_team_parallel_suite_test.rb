require_relative '../support/tournament_execution_suite'
require_relative '../support/assertions'
require 'timeout'
include GameRoomTest::Assertions

scratch = Dir.mktmpdir('team-race-', File.join(TournamentExecutionSuite::ROOT, 'tmp'))
env = {'FT2_SCRATCH' => scratch, 'ENTRY_EVIDENCE' => File.join(scratch, 'prepare')}
FileUtils.mkdir_p(env['ENTRY_EVIDENCE'])
prepared = GameRoomTestRunner.run([{script: 'test/tournaments/fixed_team_execution_parallel_prepare_test.rb', env: env}],
  report: File.join(scratch, 'prepare.json'))
raise 'Team race preparation failed' unless GameRoomTestRunner.success?(prepared)
input = File.join(scratch, 'shared/prepare/parallel-input.json')
assert(File.file?(input), 'Preparation did not produce a real shared plan')
barrier = File.join(scratch, 'barrier')
FileUtils.mkdir_p(barrier)
children = []
begin
  2.times do |index|
    evidence = File.join(scratch, "player-#{index}")
    FileUtils.mkdir_p(evidence)
    child_env = env.merge('ENTRY_EVIDENCE' => evidence, 'FT2_PAIR_INDEX' => index.to_s,
      'FT2_PAIR_INPUT' => input, 'FT2_PAIR_BARRIER' => barrier)
    log = File.join(evidence, 'output.log')
    pid = Process.spawn(child_env, RbConfig.ruby, 'test/tournaments/fixed_team_execution_parallel_test.rb', out: log, err: [:child, :out])
    children << {pid: pid, evidence: evidence, log: log}
  end
  Timeout.timeout(30) do
    sleep 0.01 until 2.times.all? { |index| File.file?(File.join(barrier, "ready-#{index}")) }
  end
  File.write(File.join(barrier, 'go'), 'start')
  children.each do |child|
    _, status = Timeout.timeout(150) { Process.wait2(child[:pid]) }
    child[:joined] = true
    assert(status.success?, File.read(child[:log], encoding: 'UTF-8'))
  end
  outcomes = children.map { |child| JSON.parse(File.read(File.join(child[:evidence], 'parallel-result.json'))) }
  assert_equal(%w[blocked bound], outcomes.map { |row| row['state'] }.sort)
  state = JSON.parse(File.read(File.join(scratch, 'shared/prepare/plany/fixed-teams-v1/execution-ft2-v1/state.json')))
  assert_equal(1, state['native']['creates'].size)
  assert_equal(4, state['busy'].size)
  puts 'PASS two actual processes race overlapping team matches: one table, one rejection, four reserved accounts'
ensure
  children.reject { |child| child[:joined] }.each do |child|
    Process.kill('KILL', child[:pid]) rescue Errno::ESRCH
    Process.wait(child[:pid]) rescue Errno::ECHILD
  end
end
