require_relative '../run'
require 'tmpdir'

Dir.mktmpdir('tournament-result-', File.join(GameRoomTestRunner::ROOT, 'tmp')) do |directory|
  script = 'test/tournaments/ordinary_match_service_test.rb'
  jobs = [
    {script: script, env: {'TOURNAMENT_RESULT_READ_FAILURE' => '1', 'TOURNAMENT_RESULT_LOST_ACK' => nil}},
    {script: script, env: {'TOURNAMENT_RESULT_READ_FAILURE' => nil, 'TOURNAMENT_RESULT_LOST_ACK' => '1'}}
  ]
  results = GameRoomTestRunner.run(jobs, report: File.join(directory, 'results.json'))
  raise "Tournament result recovery failed: #{directory}" unless GameRoomTestRunner.success?(results)
end
puts 'PASS result retained before read failure and reconciled after lost acknowledgement, without duplicate scoring'
