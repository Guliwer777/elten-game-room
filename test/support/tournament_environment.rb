# encoding: UTF-8
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'rbconfig'
require_relative 'temporary_directory'

# Every standalone tournament scenario owns its scratch data. Multi-process
# suites pass the same directories explicitly so a readback can reuse the first
# process's data. Never use a developer's old diagnostic directory as a fixture.
module TournamentTestEnvironment
  ROOT = File.expand_path('../..', __dir__)
  def self.prepare
    scratch = ENV['FT2_SCRATCH'] || ENV['ENTRY_SCRATCH'] || GameRoomTest::TemporaryDirectory.create('pg-tournament-')
    scratch = File.expand_path(scratch)
    %w[FT1_SCRATCH FT2_SCRATCH ENTRY_SCRATCH].each { |name| ENV[name] ||= scratch }
    ENV['FT2_SOURCE'] ||= ROOT
    ENV['ENTRY_EVIDENCE'] ||= File.join(scratch, 'evidence')
    ENV['COORD_EVIDENCE_DIR'] ||= ENV['ENTRY_EVIDENCE']
    [ENV['ENTRY_EVIDENCE'], ENV['COORD_EVIDENCE_DIR']].uniq.each { |path| FileUtils.mkdir_p(path) }
    metadata = {
      'source-before.json' => Dir.glob('{lib,games,content}/**/*.rb', base: ROOT).sort.to_h { |path| [path, Digest::SHA256.file(File.join(ROOT, path)).hexdigest] },
      'runtime-before.json' => {ruby: RUBY_DESCRIPTION, executable: RbConfig.ruby},
      'tools-before.json' => Dir.glob('tools/**/*.rb', base: ROOT).sort.to_h { |path| [path, Digest::SHA256.file(File.join(ROOT, path)).hexdigest] }
    }
    metadata.each do |name, value|
      path = File.join(ENV['ENTRY_EVIDENCE'], name)
      File.write(path, JSON.pretty_generate(value)) unless File.exist?(path)
    end
  end
end
TournamentTestEnvironment.prepare
