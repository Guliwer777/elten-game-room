# encoding: UTF-8
require_relative 'tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
directory, now, expected_hash = ARGV
program = TournamentEntryContextTest::Program.new(directory)
sandbox = File.join(directory, 'tournament-local-test-' + Digest::SHA256.hexdigest(F::OWNER.downcase))
plans = File.join(sandbox, 'plans')
path = File.join(plans, 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
state = JSON.parse(File.read(path))
record = state.fetch('records').values.first
fixture = {program: program, plans: plans, sandbox: sandbox, now: Integer(now)}
begin
  F.with_execution(fixture, 'Anna') do |execution|
    F.select_execution(execution, record, history: true)
    result = execution.local_game(action: :local_game_status)
    assert_equal(:confirmed, result[:state])
    assert_equal(6, result[:status]['event_count'])
    assert_equal('playing', result[:status]['phase'])
  end
  data = state['executions'].values.find { |r| r['start'] }
  core = state['native']['cores'].first
  T::LocalFixedTeamMoves.with_core(core, data, owner: core['owner']) do |_tx, _transport, _table, repository, session|
    snapshot = repository.snapshot_for(session, force_events: true)
    replay = F::REGISTRY.build('spades').replay(snapshot.session, snapshot.events, repository)
    assert_equal(expected_hash, Digest::SHA256.hexdigest(JSON.generate(replay.state)))
  end
  assert_equal(0, program.class.app_runtime.managed_resources.size)
  puts 'PASS cold moves: complete state, hands and seed replay agree in fresh process'
ensure
  program.finalize
  program.class.app_runtime.close
end
