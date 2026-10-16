# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
provider = TournamentFixedTeamNativeService.new
matches = record['evidence']['plan']['matches']
[0, 1].each do |index|
  matches[index]['players'].each do |person|
    execution_for(context, record, person['username']) do |facade|
      select_match(facade, record, index)
      assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
end
first = nil
actor = matches[0]['players'].first['username']
execution_for(context, record, actor, native_provider: provider) do |facade|
  select_match(facade, record)
  first = facade.request_match
  assert_equal(:bound, first[:state])
end
execution_for(context, record, matches[1]['players'].first['username'], native_provider: provider) do |facade|
  select_match(facade, record, 1)
  assert_equal(:participants_busy, facade.request_match[:reason])
end
path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
before = JSON.parse(File.binread(path))
assert_equal(matches[0]['players'].map { |person| person['account'] }.sort, before['busy'].keys.sort)
assert_equal(1, before['native']['creates'].size)
execution_for(context, record, actor) do |facade|
  select_match(facade, record)
  assert_equal(:confirmed, facade.declare(availability: 'withdrawn', expected_revision: 1)[:state])
end
after = JSON.parse(File.binread(path))
execution = after['executions'].values.find { |row| row['request']['match_id'] == matches[0]['match_id'] }
oracle_file('busy-withdraw-before-assert.json', {before: before, after: after, target: first[:target].to_h})
assert_equal(nil, execution['grant'], 'RED_FT2A_WITHDRAW: wycofanie nie unieważnia grantu wspólnego składu')
assert_equal(before['busy'], after['busy'], 'Niepewne lub zajęte membership nie zwalnia się automatycznie')
execution_for(context, record, actor, native_provider: provider) do |facade|
  select_match(facade, record)
  recovered = facade.reconcile
  assert_equal(:blocked, recovered[:state])
  assert_equal(:stale_grant, recovered[:reason])
  assert_equal(before['native']['creates'], after['native']['creates'], 'Withdrawal must retain the original target history')
end
assert_equal(after, JSON.parse(File.binread(path)), 'Reconcile po withdraw bez mutacji biznesowej')
puts 'GREEN: cały skład busy wobec innego meczu; withdraw cofa grant, ale zachowuje exact readback'
