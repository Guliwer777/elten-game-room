require 'json'
require 'stringio'
require_relative '../run'
require_relative '../support/assertions'
require_relative '../support/temporary_directory'
include GameRoomTest::Assertions

GameRoomTest::TemporaryDirectory.create('runner-unicode-') do |folder|
  path = File.join(folder, 'unicode.rb')
  report = File.join(folder, 'result.json')
  text = "Zażółć gęślą jaźń — Příliš žluťoučký, Español, Русский.\n"
  File.write(path, "STDOUT.binmode; STDOUT.sync = true; STDOUT.write(#{text.dump}); STDERR.binmode; STDERR.write(\"\\xFF\".b)\n")
  result = GameRoomTestRunner.run([path], output: StringIO.new, report: report).fetch(0)
  assert_equal('passed', result.fetch(:outcome))
  assert_equal(text + "\uFFFD", result.fetch(:output), 'Valid UTF-8 output was damaged while replacing an invalid byte')
  assert_equal(result.fetch(:output), JSON.parse(File.read(report)).first.fetch('output'),
    'The persisted report differs from the captured Unicode output')
end
puts 'PASS runner preserves Unicode diagnostic text and replaces only invalid bytes in the report'
