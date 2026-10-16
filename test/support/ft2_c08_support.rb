# encoding: UTF-8
require_relative 'tournament_fixed_team_execution'
require_relative 'tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
module FT2C08Support
  include TournamentFixedTeamExecutionSupport

  def c08_bound_fixture
    context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
    players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
    players.each do |actor|
      execution_for(context, record, actor) do |facade|
        select_match(facade, record)
        assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
      end
    end
    execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
      select_match(facade, record)
      assert_equal(:bound, facade.request_match[:state])
    end
    path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
    [context, record, players, path, File.binread(path)]
  end

  def c08_observe
    mutations = []
    trace = TracePoint.new(:call) do |e|
      mutations << [e.defined_class.to_s, e.method_id.to_s] if
        ([T::ReadinessJournal, T::CoordinationJournal].include?(e.defined_class) && e.method_id == :claim) ||
        (e.defined_class == TournamentFixedTeamNativeService::Broker::Endpoint && e.method_id == :create) ||
        (e.defined_class == T::LocalFixedTeamExecutionStorage && e.method_id == :write)
    end
    trace.enable(target_thread: nil)
    begin
      value = yield
    ensure
      trace.disable
    end
    [value, mutations]
  end

  def c08_corruption(context, record, path, healthy, variants)
    rows = []
    variants.each do |name, mutate|
      document = JSON.parse(healthy)
      mutate.call(document)
      bytes = JSON.generate(document)
      File.binwrite(path, bytes)
      actor = record['evidence']['plan']['matches'].fetch(1)['players'].first['username']
      result, mutations = c08_observe do
        execution_for(context, record, actor) do |facade|
          select_match(facade, record, 1)
          break facade.declare(availability: 'ready', expected_revision: 0)
        end
      end
      expected = {result: {state: :blocked, reason: :sandbox_corrupt, current: nil, receipt: nil, operation_id: nil}, exact: true, mutations: []}
      actual = {result: result, exact: File.binread(path) == bytes.b, mutations: mutations}
      rows << {variant: name, expected: expected, actual: actual, before: document, after: JSON.parse(File.binread(path))}
      File.binwrite(path, healthy)
    end
    oracle_file('ft2_c08_relations.json', rows)
    rows.each { |row| assert_equal(row[:expected], row[:actual], "RED_FT2A_C08_RELATION: #{row[:variant]}") }
  end
end
