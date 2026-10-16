# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
context, service, reference = fixture
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
with_backend(context) do |backend|
  record = backend.accept(preview: backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'untrusted'))
  a = T::ExecutionPlanContract
  game = REGISTRY.build('spades')
  match = record['evidence']['plan']['matches'].first
  options, people = match.values_at('options', 'players')
  invalid = [[nil, people, TEMPLATE], [[], people, TEMPLATE], [options, nil, TEMPLATE], [options, people, ['0', 1, 0, 1]],
    [options, people, [0, 1, 0, 1.0]], [options, people, [-1, 1, 0, 1]], [options, people, [0, 2, 0, 1]],
    [options.merge('team_players' => NAMES.first(4)), people, TEMPLATE],
    [options, people.map { |person| person.merge('account' => 'obcy') }, TEMPLATE]]
  calls = []
  trace = TracePoint.new(:call) { |event| calls << event.method_id if event.defined_class == GameRoomTeams::Assignment && event.method_id == :initialize }
  trace.enable(target_thread: nil)
  begin
    errors = invalid.map do |opts, persons, seats|
      error = assert_raises(T::Publication::Invalid) { T::FixedTeamSeats.native(game: game, options: opts, people: persons, template: seats) }
      error.code
    end
  ensure
    trace.disable
  end
  assert_equal([], calls)
  mutations = [
    ->(source) { source['options'] = nil },
    ->(source) { source['rematch'] = 'true' },
    ->(source) { source['pairing'] = 'nieznane' },
    ->(source) do
      names = (1..34).map { |i| "Osoba#{i}" }
      source['roster'] = names.map { |name| {'account' => name.downcase, 'username' => name} }.sort_by { |p| p['account'] }
      source['membership'] = {'version' => 1, 'kind' => 'fixed-teams', 'units' => names.each_slice(2).with_index.map { |pair, i| {'unit_id' => "unit-#{i}", 'accounts' => pair.map(&:downcase).sort} }.sort_by { |u| u['unit_id'] }}
    end
  ]
  generated = []
  trace = TracePoint.new(:call) { |event| generated << event.method_id if event.defined_class == T::LeaguePlan.singleton_class && event.method_id == :build }
  trace.enable(target_thread: nil)
  begin
    rejection = mutations.map do |change|
      value = a.copy(record['evidence'])
      change.call(value['source'])
      error = assert_raises(T::Publication::Invalid) { a.validate(value, record['expected_source'], registry: REGISTRY) }
      error.code
    end
  ensure
    trace.disable
  end
  assert_equal([], generated, 'Niezaufany dowód nie generuje kombinacji nad budżetem')
  oracle_file('oracle.json', {'native_invalid' => invalid, 'native_codes' => errors, 'assignment_calls' => calls, 'source_codes' => rejection, 'league_calls' => generated})
end
puts 'FT1: niezaufane typy adaptera i przedwykonawczy budżet A — OK'
