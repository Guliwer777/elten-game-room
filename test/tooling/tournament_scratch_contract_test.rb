require 'open3'
require 'rbconfig'
require_relative '../support/assertions'
include GameRoomTest::Assertions

root = File.expand_path('../..', __dir__)
script = <<~'RUBY'
  require_relative 'test/support/temporary_directory'
  raise 'Child inherited a TMPDIR' if ENV.key?('TMPDIR')
  GameRoomTest::TemporaryDirectory.create('tournament-scratch-contract-') do |owned|
    ENV['FT2_SCRATCH'] = owned
    ENV['ENTRY_SCRATCH'] = owned
    require_relative 'test/support/tournament_environment'
    raise 'Tournament bootstrap changed the global TMPDIR' if ENV.key?('TMPDIR')
    require_relative 'test/support/tournament_coordination_file_port'
    require_relative 'test/support/tournament_restart_process'
    fixture = TournamentCoordinationFixture
    path = nil
    fixture.isolated do |directory|
      expected = File.realpath(GameRoomTest::TemporaryDirectory.parent)
      raise 'Coordination directory escaped the helper parent' unless File.realpath(File.dirname(directory)) == expected
      TournamentRestartProcess.safe_path(directory)
      path = File.join(directory, 'port.json')
      TournamentCoordinationFilePort.new(fixture.request, state_path: path, account: 'alice')
      raise 'Native file fixture did not initialize its own state' unless File.file?(path)
    end
    raise 'Coordination fixture leaked its owned directory' if File.exist?(path)
    [GameRoomTest::TemporaryDirectory::ROOT, GameRoomTest::TemporaryDirectory.parent].each do |outside|
      begin
        TournamentRestartProcess.safe_path(outside)
        raise 'Unexpected accepted restart root'
      rescue RuntimeError => error
        raise if error.message == 'Unexpected accepted restart root'
      end
      begin
        TournamentCoordinationFilePort.new(fixture.request, state_path: File.join(outside, 'must-not-write.json'), account: 'alice')
        raise 'Unexpected accepted file port root'
      rescue RuntimeError => error
        raise if error.message == 'Unexpected accepted file port root'
      end
      raise 'Guard wrote outside its owned child directory' if File.exist?(File.join(outside, 'must-not-write.json'))
    end
    raise 'Fixture changed the global TMPDIR' if ENV.key?('TMPDIR')
  end
  puts 'workspace children only; parent roots rejected; global TMPDIR unchanged'
RUBY
output, status = Open3.capture2e({'TMPDIR' => nil, 'FT2_SCRATCH' => nil, 'ENTRY_SCRATCH' => nil,
  'ENTRY_EVIDENCE' => nil, 'COORD_EVIDENCE_DIR' => nil}, RbConfig.ruby, '-e', script, chdir: root)
assert(status.success?, "Tournament scratch boundary failed: #{output}")
assert(output.include?('global TMPDIR unchanged'))
puts 'PASS tournament scratch uses the shared workspace helper without a global environment override'
