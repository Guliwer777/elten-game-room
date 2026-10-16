# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
match = record['evidence']['plan']['matches'].first
players = match['players'].map { |p| p['username'] }
path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
receipts = []; denied = []; requests = []
%w[Organizator Obserwator Celina].each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    result = facade.declare(availability: 'ready', expected_revision: 0)
    assert_equal(:not_participant, result[:reason])
    denied << {actor: actor, result: result}
  end
end
assert(!File.exist?(path), 'Obce role nie zapisują wspólnego state')
players.each_with_index do |actor, index|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    result = facade.declare(availability: 'ready', expected_revision: 0)
    assert_equal(:confirmed, result[:state])
    assert_equal(actor.downcase, result[:receipt]['operation']['account'])
    assert_equal(match['windows'].first['opens'] + 1, result[:receipt]['result']['server_time'])
    receipts << result
  end
  next unless [1, 2, 3].include?(index)
  execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
    select_match(facade, record)
    result = facade.request_match
    if index < 3
      assert_equal(:not_all_ready, result[:reason], 'Jedna para ani trzy osoby nie stanowią pełnej gotowości')
      state = JSON.parse(File.binread(path))
      assert_equal({}, state['busy']); assert_equal([], state['native']['creates'])
    else
      assert_equal(:bound, result[:state])
    end
    requests << result.merge(binding: result[:binding]&.to_h, target: result[:target]&.to_h)
  end
end
bound = JSON.parse(File.binread(path))
assert_equal(players.map(&:downcase).sort, bound['busy'].keys.sort)
assert_equal(1, bound['native']['creates'].size)
execution = bound['executions'].values.first
assert_equal(players.first.downcase, execution['grant']['holder_account'])
assert_equal(match['windows'].first['closes'] - 1, execution['grant']['expires_at'])
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    result = facade.declare(availability: 'withdrawn', expected_revision: 1)
    assert_equal(:confirmed, result[:state]); assert_equal(actor.downcase, result[:receipt]['operation']['account'])
    assert_equal('withdrawn', facade.current[:current]['state'])
    receipts << result
  end
end
after = JSON.parse(File.binread(path))
assert_equal(nil, after['executions'].values.first['grant'])
assert_equal(bound['busy'], after['busy'])
assert_equal(bound['native'], after['native'])
wrong = nil
actor_backend(context, players.first) do |backend, authority, directory|
  begin
    T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory + '-drugi',
      source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
      clock: -> { match['windows'].first['opens'] + 1 }, policy_ref: 'jawna-polityka', expires_at: match['windows'].first['closes'] - 1)
  rescue T::Publication::Invalid => error
    wrong = error.code
  end
  assert(!File.exist?(directory + '-drugi'))
end
assert_equal(:invalid_composition, wrong)
oracle_file('own-four-readiness.json', {record: record, denied: denied, receipts: receipts, requests: requests,
  bound: bound, withdrawn: after, alternate_directory_reason: wrong})
puts 'GREEN: własne ready/withdraw czterech kont, odmowa jednej parze/trzem/obcym rolom, busy i jedna ścieżka'
