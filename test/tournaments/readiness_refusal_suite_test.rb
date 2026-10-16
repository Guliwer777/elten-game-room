require_relative '../support/tournament_execution_suite'
scratch = Dir.mktmpdir('refusal-', File.join(TournamentExecutionSuite::ROOT, 'tmp'))
entries = %w[pl en fallback].product(%w[legal mapping]).map.with_index do |args, index|
  evidence = File.join(scratch, index.to_s)
  FileUtils.mkdir_p(evidence)
  {script: 'test/tournaments/local_readiness_refusal_test.rb', args: args,
    env: {'ENTRY_EVIDENCE' => evidence, 'ENTRY_SCRATCH' => scratch, 'FT2_SCRATCH' => scratch}}
end
results = GameRoomTestRunner.run(entries, report: File.join(scratch, 'results.json'))
raise "Readiness refusal checks failed: #{scratch}" unless GameRoomTestRunner.success?(results)
puts 'PASS native PL/EN/missing-translation readiness refusals without mutations'
