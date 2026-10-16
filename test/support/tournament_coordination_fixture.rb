# encoding: UTF-8
require 'tmpdir'
require 'fileutils'
require_relative 'tournament_match_data'
path = File.expand_path('../../lib/tournaments/coordination_service.rb', __dir__)
require path if File.file?(path) && !defined?(GameRoomTournaments::CoordinationService)

module TournamentCoordinationFixture
  module_function
  def assert(value, message)
    raise message unless value
  end
  def request(game: 'uno', names: %w[Alice Bob])
    TournamentMatchFixture.payload(game_id: game, names: names)
      .reject { |k, _| %w[reservation create native_uuid table_id].include?(k) }
      .merge('window' => {'id'=>'window-1','opens'=>100,'closes'=>200,'policy_ref'=>'test-only-window-policy'},
        'visibility'=>'private')
  end
  def context(account: 'alice')
    {'account'=>account, 'backend_identity'=>'fixture:owner','runtime'=>'runtime-1',
      'generation'=>'execution-1','epoch'=>1,'cancelled'=>false,'grant_epoch'=>1}
  end
  def isolated
    raise 'TMP poza scratch' unless File.identical?(Dir.tmpdir, ENV.fetch('TMPDIR'))
    directory=Dir.mktmpdir('coordination-')
    value=yield directory
    FileUtils.remove_entry(directory)
    value
  end
end
