require_relative '../support/tournament_execution_suite'
require_relative '../support/assertions'
require 'stringio'
include GameRoomTest::Assertions

root = TournamentExecutionSuite::ROOT
families = TournamentExecutionSuite::GROUPS.keys + %w[encoding cold recovery compatibility]
families.each do |family|
  jobs = TournamentExecutionSuite.jobs(family)
  assert(!jobs.empty?, "Empty tournament group: #{family}")
  jobs.each { |job| assert(File.file?(File.join(root, job[:script])), "Missing entry point: #{job[:script]}") }
end
paths = GameRoomTestSuites.paths(root: root)
assert(paths.none? { |path| File.basename(path).start_with?('ft2b1_', 'ft2_runtime_cold_', 'ft2_compatibility_boundary_') },
  'Parameterized or historical children counted again')
families.each do |family|
  assert(paths.include?("test/tournaments/execution_#{family}_suite_test.rb"), "Missing aggregate: #{family}")
end
assert_equal(paths.select { |path| path.start_with?('test/tournaments/') },
  GameRoomTestRunner.expand(['test/tournaments']).map { |job| job[:script] })
historical = 'test/tournaments/ft2b1_ui_primary_test.rb'
assert_equal([historical], GameRoomTestRunner.expand([historical]).map { |job| job[:script] }, 'Explicit historical invocation lost')
assert_equal(%w[source binary].product(%w[pl en missing-new-pl]), TournamentExecutionSuite.jobs('encoding').map { |job| job[:args] })
runtime = TournamentExecutionSuite.jobs('recovery').select { |job| job[:script].include?('ft2_runtime_cold_') }
assert_equal(%w[runtime-a runtime-b], runtime.map { |job| job[:evidence_name] }, 'Cold B must use the same fixture as A')
assert(runtime.all? { |job| !job.key?(:args) }, 'Cold scripts do not take synthetic CLI phases')
native = TournamentExecutionSuite.jobs('recovery').select { |job| job[:script].include?('ft2b1_native_cold_') }
assert_equal([['A', 'suite'], ['B', 'suite']], native.map { |job| job[:args] })

Dir.mktmpdir('tournament-suite-', File.join(root, 'tmp')) do |scratch|
  jobs = TournamentExecutionSuite.entries('encoding', scratch: scratch)
  jobs.each do |job|
    env = job[:env]
    assert_equal(root, env['FT2_SOURCE'])
    assert(File.directory?(env['ENTRY_EVIDENCE']), 'Evidence directory missing')
    map = JSON.parse(File.read(File.join(env['ENTRY_EVIDENCE'], 'source-before.json')))
    assert(map.key?('lib/tournaments/entry_context.rb'), 'Binary loader has no pinned production source')
    assert_equal(Digest::SHA256.file(File.join(root, 'lib/tournaments/entry_context.rb')).hexdigest, map['lib/tournaments/entry_context.rb'])
  end
  kept = TournamentExecutionSuite.read_catalog(File.join(scratch, 'shared/missing/PL.mo'))
  removed = JSON.parse(File.read(File.join(scratch, 'shared/missing/removed.json')))
  assert_equal(33, removed.size)
  assert(removed.none? { |key| kept.key?(key.b) }, 'Missing-translation test retained new translations')
  assert_equal('Wstecz', kept.fetch('Back').force_encoding('UTF-8'), 'Old translation removed')
  current = TournamentExecutionSuite.read_catalog(File.join(root, 'locale/PL.mo'))
  assert_equal(current.size - removed.size, kept.size)
end
puts 'PASS maintained tournament groups, explicit historic invocation, real cold phases and isolated encoding fixtures'
