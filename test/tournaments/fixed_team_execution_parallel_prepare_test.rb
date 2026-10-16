# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
[0, 1].each do |index|
  record['evidence']['plan']['matches'][index]['players'].each do |person|
    execution_for(context, record, person['username']) do |facade|
      select_match(facade, record, index)
      assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
end
File.open(File.join(context.directory, 'parallel-input.json'), 'wx:UTF-8') do |file|
  file.write(JSON.pretty_generate({'directory' => context.directory, 'record' => record}))
end
puts 'GREEN: wspólny przyjęty FT1 i własna gotowość dwóch nakładających się meczów'
