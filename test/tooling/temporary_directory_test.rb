require_relative '../support/temporary_directory'
require_relative '../support/assertions'
include GameRoomTest::Assertions

Dir.mktmpdir('fresh-test-workspace-') do |outer|
  root = File.join(outer, 'checkout')
  assert(!File.exist?(root), 'The fixture must start without a workspace or tmp directory')
  first = GameRoomTest::TemporaryDirectory.create('first-', root: root)
  assert(File.directory?(first))
  assert_equal(File.join(root, 'tmp'), File.dirname(first))
  File.write(File.join(first, 'evidence.txt'), 'keep')

  second = Dir.chdir(outer) { GameRoomTest::TemporaryDirectory.create('second-', root: root) }
  assert(first != second, 'Scenarios must not share scratch data')
  assert_equal(File.join(root, 'tmp'), File.dirname(second))
  assert_equal('keep', File.read(File.join(first, 'evidence.txt')))

  scoped = nil
  result = GameRoomTest::TemporaryDirectory.create('scoped-', root: root) do |path|
    scoped = path
    assert(File.directory?(path))
    :returned
  end
  assert_equal(:returned, result)
  assert(!File.exist?(scoped), 'A block must clean up only its own directory')
  assert(File.directory?(first) && File.directory?(second), 'Other evidence was removed')

  failed = nil
  assert_raises(IOError) do
    GameRoomTest::TemporaryDirectory.create('failed-', root: root) do |path|
      failed = path
      raise IOError, 'scenario failed'
    end
  end
  assert(!File.exist?(failed), 'A failing block leaked its scratch directory')
  assert_equal('keep', File.read(File.join(first, 'evidence.txt')))
end
puts 'PASS fresh workspace scratch directory, independent scenarios and scoped cleanup'
