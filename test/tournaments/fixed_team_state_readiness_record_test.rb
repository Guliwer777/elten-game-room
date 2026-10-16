# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
execution_for(context, record, players.first) do |facade|
  select_match(facade, record)
  assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
end
path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
healthy = File.binread(path)
rows = []
[:plan_digest, :roster_generation, :czlonkostwo, :plan_id].each do |variant|
  document = JSON.parse(healthy)
  receipt = document['readiness'].first
  op = receipt['operation']
  case variant
  when :plan_digest then op['accepted_match']['plan_digest'] = 'f' * 64
  when :roster_generation then op['request']['match_ref']['roster_generation'] = 'inna-generacja'
  when :czlonkostwo then op['accepted_match']['members'].last['account'] = 'obcy'
  when :plan_id then op['request']['match_ref']['plan_id'] = SecureRandom.uuid
  end
  op = T::ReadinessContract.operation(op['request'], op['account'], op['accepted_match'], op['operation_id'])
  receipt['operation'] = op; receipt['request_digest'] = op['request_digest']
  T::ReadinessContract.response!(receipt, op)
  bytes = JSON.generate(document); File.binwrite(path, bytes)
  result = nil
  execution_for(context, record, players.last) do |facade|
    select_match(facade, record)
    result = facade.current
  end
  rows << {variant: variant, earlier_gate: 'ReadinessContract.operation!/response! przyjęły zmieniony dokument',
    actual: result, expected: :sandbox_corrupt, before: document, after: JSON.parse(File.binread(path)), exact: File.binread(path) == bytes.b}
end
File.binwrite(path, healthy)
oracle_file('state-readiness-record.json', rows)
rows.each do |row|
  assert(row[:actual][:state] == :blocked && row[:actual][:reason] == :sandbox_corrupt && row[:exact],
    'RED_FT2A_READINESS_RECORD: poprawny kontrakt receipt nie nadaje autorytetu bez zgodności z FT1')
end
puts 'GREEN: gotowość wszystkich zapisów jest związana z rzeczywistym przyjętym FT1'
