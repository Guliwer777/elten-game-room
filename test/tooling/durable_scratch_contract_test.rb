require 'open3'
require 'rbconfig'
require_relative '../support/assertions'
include GameRoomTest::Assertions

root = File.expand_path('../..', __dir__)
script = <<~RUBY
  require_relative 'test/support/temporary_directory'
  require_relative 'test/support/durable_save_fixture'
  raise 'The fixture initialized a global TMPDIR' if ENV.key?('TMPDIR')
  GameRoomTest::TemporaryDirectory.create('durable-scratch-') do |directory|
    DurableSaveFixture.root!(directory)
    DurableSaveFixture.dump(File.join(directory, 'proof.json'), {'local' => true})
    raise 'Scratch readback differs' unless DurableSaveFixture.read(File.join(directory, 'proof.json')) == {'local' => true}
    [GameRoomTest::TemporaryDirectory::ROOT, File.join(GameRoomTest::TemporaryDirectory::ROOT, 'tmp-sibling')].each do |outside|
      rejected = false
      begin
        DurableSaveFixture.root!(outside)
      rescue RuntimeError
        rejected = true
      end
      raise 'The fixture accepted an unrelated directory' unless rejected
    end
  end
  raise 'The fixture changed global TMPDIR' if ENV.key?('TMPDIR')
  puts 'isolated scratch accepted; foreign paths refused'
RUBY
output, status = Open3.capture2e({'TMPDIR' => nil}, RbConfig.ruby, '-e', script, chdir: root)
assert(status.success?, "Durable save fixture depends on caller TMPDIR: #{output}")
assert(output.include?('foreign paths refused'))
puts 'PASS durable-save scratch without global environment or access outside the workspace test directory'
