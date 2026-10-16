# encoding: UTF-8
require_relative 'tournament_ft2b1_execution'
F = TournamentFT2B1
directory, now, revision, operation_id, gate = ARGV
program = TournamentEntryContextTest::Program.new(directory)
sandbox = File.join(directory, 'tournament-local-test-' + Digest::SHA256.hexdigest(F::OWNER.downcase))
plans = File.join(sandbox, 'plans')
state = JSON.parse(File.read(File.join(plans, 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')))
record = state.fetch('records').values.first
fixture = {program: program, plans: plans, sandbox: sandbox, now: Integer(now)}
begin
  F.with_execution(fixture, 'Beata') do |execution|
    F.select_execution(execution, record)
    File.write(gate + '.' + operation_id, 'ready')
    until File.exist?(gate)
      sleep(0.01)
    end
    result = execution.local_game(action: :local_game_move, operation_id: operation_id, revision: revision,
      move_selection: {'kind' => 'command', 'action' => 'deal'})
    puts JSON.generate(state: result[:state], reason: result[:reason], effect: result[:effect])
  end
ensure
  program.finalize
  program.class.app_runtime.close
end
