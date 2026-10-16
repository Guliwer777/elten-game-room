# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
index = Integer(ENV.fetch('FT2_PAIR_INDEX'))
input = JSON.parse(File.binread(ENV.fetch('FT2_PAIR_INPUT')))
context = TournamentPublicServiceSupport::Context.new(input['directory'], 'Organizator')
context.now = 201
record = input['record']
actor = record['evidence']['plan']['matches'][index]['players'].first['username']
barrier = ENV.fetch('FT2_PAIR_BARRIER')
File.write(File.join(barrier, "ready-#{index}"), Process.pid.to_s)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
until File.exist?(File.join(barrier, 'go'))
  raise 'Nie otrzymano sygnału wspólnego startu' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  sleep 0.01
end
result = nil
execution_for(context, record, actor, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record, index)
  result = facade.request_match
end
assert([:bound, :blocked].include?(result[:state]))
assert_equal(:participants_busy, result[:reason]) if result[:state] == :blocked
oracle_file('parallel-result.json', {pid: Process.pid, index: index, state: result[:state], reason: result[:reason],
  target: result[:target]&.to_h})
puts "GREEN: proces #{index} zakończony wynikiem #{result[:state]} / #{result[:reason]}"
