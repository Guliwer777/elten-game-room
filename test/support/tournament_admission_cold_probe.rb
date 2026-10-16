# encoding: UTF-8
require_relative 'tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
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
    read = execution.admission(action: :admission_status)
    assert_equal(:confirmed, read[:state])
    assert_equal('anna', read[:status]['entry']['account'])
    assert_equal('joined', read[:status]['entry']['status'])
    assert_equal(3, read[:status]['participants'].size)
    assert_equal(false, read[:status]['current'])
  end
  puts 'PASS cold admission readback in fresh process'
ensure
  program.finalize
  program.class.app_runtime.close
end
