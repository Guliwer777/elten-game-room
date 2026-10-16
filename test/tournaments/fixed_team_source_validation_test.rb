# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
context, service, reference = fixture
inputs = []
wrong = membership
wrong['units'][0]['accounts'][0] = 'intruz'
inputs << [wrong, TEMPLATE, :invalid_membership]
wrong = membership
wrong['units'][0]['accounts'] << 'anna'
inputs << [wrong, TEMPLATE, :invalid_membership]
wrong = membership
wrong['units'][1]['unit_id'] = 'UNIT-a'
inputs << [wrong, TEMPLATE, :invalid_membership]
wrong = membership
wrong['units'][0]['unit_id'] = 'team:0'
inputs << [wrong, TEMPLATE, :invalid_membership]
wrong = membership
wrong['units'].pop
inputs << [wrong, TEMPLATE, :invalid_membership]
wrong = membership
wrong['version'] = 1.0
inputs << [wrong, TEMPLATE, :invalid_membership]
[nil, [], [0, 1, 0], [0, 1, 0, '1'], [0, 1, 0, 1.0], [0, -1, 0, 1], [0, 2, 0, 1], [0, 0, 0, 1]].each do |template|
  inputs << [membership, template, :invalid_team_template]
end
writes, assignments = [], []
trace = TracePoint.new(:call) do |event|
  writes << event.method_id if event.method_id == :write && event.defined_class.to_s.include?('LocalExecutionPlanStorage')
  assignments << event.method_id if event.method_id == :initialize && event.defined_class == GameRoomTeams::Assignment
end
trace.enable(target_thread: nil)
begin
  results = inputs.map do |members, template, code|
    error = assert_raises(T::Publication::Invalid) do
      service.fixed_team_execution_source(publication_ref: reference, membership: members, team_template: template)
    end
    assert_equal(code, error.code, 'Precyzyjna odmowa surowego wejścia')
    {'membership' => members, 'template' => template, 'code' => error.code}
  end
ensure
  trace.disable
end
assert_equal([], assignments, 'Walidacja przed liberalnym Assignment')
assert_equal([], writes, 'Odmowa bez zapisu planu')
oracle_file('oracle.json', {'rejections' => results, 'assignments' => assignments, 'writes' => writes})
puts 'FT1: ścisłe membership i template — OK'
