# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
results = []
[1, 3].each do |index|
  context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + "-#{index}")
  target = record['evidence']['plan']['matches'][index]
  target['players'].each do |person|
    execution_for(context, record, person['username']) do |facade|
      select_match(facade, record, index)
      assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  actor = (target['players'].map { |p| p['username'] } & record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }).first
  execution_for(context, record, actor, native_provider: TournamentFixedTeamNativeService.new) do |facade|
    first = select_match(facade, record)
    epoch = facade.coordinator_epoch
    expected = select_match(facade, record, index)
    requests = []
    trace = TracePoint.new(:call) do |point|
      if point.defined_class == T::LocalFixedTeamCoordinationPort && point.method_id == :snapshot
        requests << point.binding.local_variable_get(:request)
      end
    end
    begin
      trace.enable(target_thread: nil)
      actual = facade.request_match
    ensure
      trace.disable
    end
    path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
    row = {index: index, first: first[:request].to_h, epoch: epoch, expected: expected[:request].to_h,
      result: actual.merge(binding: actual[:binding]&.to_h, target: actual[:target]&.to_h), requests: requests,
      state: JSON.parse(File.binread(path))}
    results << row
    oracle_file("reselect-#{index}.json", row)
  end
end
results.each do |row|
  assert_equal(:bound, row[:result][:state], 'RED_FT2A_RESELECT: ponowny select musi zmienić rzeczywisty port i cel')
  assert(row[:requests].all? { |request| request.eql?(row[:expected]) }, 'Rzeczywiste requesty należą do nowego wyboru')
  assert_equal(row[:expected]['match_id'], row[:result][:target]['binding']['match_id'])
  assert_equal(row[:expected]['leg'], row[:result][:target]['binding']['leg'])
  assert_equal(1, row[:state]['native']['creates'].size)
  assert_equal(row[:expected]['players'].map { |p| p['account'] }.sort, row[:state]['busy'].keys.sort)
end
puts 'GREEN: ta sama fasada po memoizacji wybiera drugi mecz i leg2, z rzeczywistym nowym celem'
