require 'securerandom'
require_relative '../run'
require_relative '../support/assertions'
require_relative '../support/temporary_directory'
include GameRoomTest::Assertions

GameRoomTest::TemporaryDirectory.create('runner-glob-') do |directory|
  basename = "only-current-directory-#{SecureRandom.hex(8)}_test.rb"
  File.write(File.join(directory, basename), "puts 'local fixture'\n")
  local_pattern = File.join(directory, 'only-current-directory-*_test.rb')
  assert_equal(Dir.glob(local_pattern), GameRoomTestRunner.glob(local_pattern), 'An absolute glob lost its literal parent')
  if File::ALT_SEPARATOR == '\\'
    # C: names the current directory on that drive, whereas C:/ names its root.
    # Only the isolated fixture is written; the root is read with an exact,
    # randomized wildcard and is never enumerated or modified wholesale.
    drive_root = File.expand_path(directory)[0, 3]
    pattern = drive_root + basename.sub('_test.rb', '*_test.rb')
    Dir.chdir(directory) do
      expected = Dir.glob(pattern)
      assert_equal([], expected, 'The randomized fixture unexpectedly exists in the drive root')
      assert_equal(expected, GameRoomTestRunner.glob(pattern), 'A drive-root glob selected a test from the current directory')
    end
  end
end
puts 'PASS absolute runner globs preserve their literal directory, including the Windows drive root'
