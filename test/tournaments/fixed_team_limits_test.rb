# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
names = (1..34).map { |index| "Osoba#{index}" }
context, service, reference = fixture(names: names)
large = {'version' => 1, 'kind' => 'fixed-teams', 'units' => names.each_slice(2).with_index.map { |pair, i| {'unit_id' => "unit-#{i}", 'accounts' => pair.map(&:downcase)} }}
generated = []
trace = TracePoint.new(:call) { |event| generated << event.method_id if event.defined_class == T::LeaguePlan.singleton_class && event.method_id == :build }
trace.enable(target_thread: nil)
begin
  error = assert_raises(T::Publication::Invalid) do
    service.fixed_team_execution_source(publication_ref: reference, membership: large, team_template: TEMPLATE)
  end
ensure
  trace.disable
end
assert_equal(:execution_plan_limit, error.code)
assert_equal([], generated, 'Budżet PRZED LeaguePlan, nie po zbudowaniu kombinacji')
oracle_file('oracle.json', {'members' => large, 'code' => error.code, 'generation_calls' => generated})
puts 'FT1: limit wykonawczy przed generacją — OK'
