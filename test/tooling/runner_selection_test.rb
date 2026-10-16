require_relative "../run"
require_relative "../support/binary_suite"
require_relative "../support/assertions"
require 'tmpdir'
require 'stringio'
include GameRoomTest::Assertions

root = GameRoomTestRunner::ROOT
runner = File.join(root, 'test/run.rb')
output, status = Open3.capture2e(RbConfig.ruby, runner, '--suite', 'models', '--list')
paths = output.lines.map(&:strip)
assert(status.success?, "suite listing failed: #{output}")
assert_equal(GameRoomTestSuites.select('models'), paths)
assert_equal(paths.uniq, paths, 'duplicate scenarios')
output, status = Open3.capture2e(RbConfig.ruby, runner, '--suite', 'models', 'test/model_contract_test.rb')
assert(!status.success? && output.include?('cannot be combined'), 'ambiguous selection was accepted')
expected = GameRoomTestSuites.paths
assert(expected.length > 100, 'recursive discovery omitted most scenarios')
suites = GameRoomTestSuites::NAMES.to_h { |name| [name, GameRoomTestSuites.select(name)] }
assert_equal(expected, suites.values.flatten.sort, 'missing or multiply counted primary scenarios')
assert(suites.values.all? { |items| !items.empty? }, 'empty suite')
assert_equal('native', GameRoomTestSuites.classify('test/realtime/realtime_native_receive_test.rb'))
assert_equal('models', GameRoomTestSuites.classify('test/model_contract_test.rb'))
assert_equal('integration', GameRoomTestSuites.classify('test/quiz_contributions/model_repository_test.rb'))
assert_raises(ArgumentError) { GameRoomTestSuites.select('typo') }
assert_equal(GameRoomTestSuites::ROOT_TESTS.sort, Dir.glob('test/*_test.rb', base: root).map { |entry| File.basename(entry) }.sort,
  'specific scenarios leaked into the test root')
expected.each do |entry|
  directory = entry.split('/')[1]
  assert(directory == 'games' || GameRoomTestSuites::FOLDER_SUITES.key?(directory) || GameRoomTestSuites::ROOT_TESTS.include?(directory), "unknown owner: #{entry}")
end
output, status = Open3.capture2e(RbConfig.ruby, runner, '--list')
assert(status.success? && output.lines.map(&:strip) == expected, 'default discovery differs from CI coverage')
%w[test/games/spades test/tooling].each do |directory|
  output, status = Open3.capture2e(RbConfig.ruby, runner, directory, '--list')
  assert(status.success? && output.lines.map(&:strip) == expected.select { |entry| entry.start_with?(directory + '/') }, 'directory selection omitted nested tests')
end
assert(GameRoomTestRunner.expand(['test/games/spades', 'test/games/spades/rules_test.rb']).map { |entry| entry[:script] }.uniq.length ==
  GameRoomTestRunner.expand(['test/games/spades']).length, 'overlapping selections ran a scenario twice')

parts = (1..4).map { |index| GameRoomTestRunner.shard(expected, "#{index}/4") }
assert_equal(expected, parts.flatten.map { |job| job.fetch(:script) }.sort, 'Sharding skipped or duplicated a scenario')
assert_equal(parts, (1..4).map { |index| GameRoomTestRunner.shard(expected.reverse, "#{index}/4") }, 'Sharding depends on input order')
%w[0/4 5/4 1/0 1/999999999999 1 1/-4 x/y].each do |selection|
  assert_raises(ArgumentError) { GameRoomTestRunner.shard(expected, selection) }
end
output, status = Open3.capture2e(RbConfig.ruby, runner, '--suite', 'tournaments', '--shard', '2/4', '--list')
assert(status.success?, output)
assert_equal(GameRoomTestRunner.shard(GameRoomTestSuites.select('tournaments'), '2/4').map { |job| job[:script] }, output.lines.map(&:strip))

Dir.mktmpdir('game-room-runner-options-') do |folder|
  %w[test/games/example test/support test/fixtures].each { |path| FileUtils.mkdir_p(File.join(folder, path)) }
  File.write(File.join(folder, 'test/games/example/nested_test.rb'), 'puts "nested scenario ran"')
  %w[support fixtures].each do |directory|
    File.write(File.join(folder, "test/#{directory}/example_test.rb"), 'raise "fixture executed as a scenario"')
  end
  nested = ['test/games/example/nested_test.rb']
  assert_equal(nested, GameRoomTestSuites.paths(root: folder), 'default discovery includes fixtures or omits nested scenarios')
  assert_equal(nested, GameRoomTestRunner.expand(['test'], root: folder).map { |entry| entry[:script] })
  assert_equal([File.join(folder, nested.first)], GameRoomTestRunner.expand([File.join(folder, 'test')]).map { |entry| entry[:script] }, 'absolute directory discovery differs')
  result = GameRoomTestRunner.run(['test'], root: folder, output: StringIO.new)
  assert(GameRoomTestRunner.success?(result) && result.first[:output].include?('nested scenario ran'), 'nested scenario was not executed')

  slow = File.join(folder, 'individual_quiz_finish_test.rb')
  File.write(slow, '$stdout.sync = true; puts "started"; sleep 10')
  limited = GameRoomTestRunner.run([slow], timeout: 0.2, output: StringIO.new).first
  assert_equal('timeout', limited[:outcome], 'An explicit timeout must override a slow scenario budget')
  assert(limited[:seconds] < 3, 'The explicit timeout was ignored')

  preload, scenario, check = %w[preload scenario additional].map { |name| File.join(folder, name + '.rb') }
  File.write(preload, 'RUNNER_PRELOADED = true')
  File.write(scenario, 'raise "missing preload" unless RUNNER_PRELOADED; raise "wrong env" unless ENV["GAME_ROOM_RUNNER_FIXTURE"] == "1"; raise "wrong args" unless ARGV == ["package"]; puts "scenario checked"')
  File.write(check, 'raise "suite env escaped" if ENV["GAME_ROOM_RUNNER_FIXTURE"] == "1"; puts "additional checked"')
  entries = [{script: scenario, env: {'GAME_ROOM_RUNNER_FIXTURE' => '1'}, ruby_args: ['-r', preload], args: ['package']},
    {script: check, env: {'GAME_ROOM_RUNNER_FIXTURE' => nil}}]
  assert_equal(entries.sort_by { |entry| entry[:script] },
    (1..2).flat_map { |index| GameRoomTestRunner.shard(entries, "#{index}/2") }.sort_by { |entry| entry[:script] },
    'Sharding discarded scenario arguments, environment or preloads')
  results = GameRoomTestRunner.run(entries, output: StringIO.new)
  assert(GameRoomTestRunner.success?(results) && results.length == 2, "preload/environment/arguments changed: #{results.inspect}")
  assert(results.first[:output].include?('scenario checked') && results.last[:output].include?('additional checked'), 'per-script output missing')
  report = File.join(folder, 'report.json')
  output, status = Open3.capture2e(RbConfig.ruby, runner, '--list', '--report', report, scenario)
  assert(status.success? && output.lines.map(&:strip) == [scenario] && !File.exist?(report), 'list executed a test or wrote a report')
  output, status = Open3.capture2e(RbConfig.ruby, runner, '--shard', '1/1', '--report', report, check)
  assert(status.success?, "Sharded CLI execution failed: #{output}")
  assert_equal([check], JSON.parse(File.read(report)).map { |row| row.fetch('test') })
end
assert_raises(ArgumentError) do
  BinaryTestSuite.run(['room/widget_feedback_binary_test.rb'], polish: ['widget_feedback_binary_test'])
end
FileUtils.mkdir_p(File.join(root, 'tmp'))
Dir.mktmpdir('binary-selection-', File.join(root, 'tmp')) do |folder|
  raise 'Binary fixture outside workspace' unless File.expand_path(folder).start_with?(root + '/')
  names = %w[pl en].map do |language|
    name = "../tmp/#{File.basename(folder)}/#{language}_test.rb"
    File.write(File.join(folder, "#{language}_test.rb"), <<~RUBY)
      raise 'Wrong binary language' unless ENV.fetch('GAME_ROOM_BINARY_LANGUAGE') == #{language.inspect}
      raise 'Wrong dictionary mode' unless $rules_english == #{language != 'pl'}
      puts 'Binary #{language} child checked'
    RUBY
    name
  end
  BinaryTestSuite.run(names, mode: 'dictionary', package: nil, polish: [names.first])
end
puts 'PASS unified runner: suites, explicit paths, per-process environment/preload/arguments and read-only listing'
