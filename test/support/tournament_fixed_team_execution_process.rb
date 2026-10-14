# encoding: UTF-8
require_relative 'tournament_fixed_team_execution'
require_relative 'tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'

module TournamentFixedTeamExecutionProcess
  include TournamentFixedTeamExecutionSupport

  class LostResponse < StandardError; end
  class LosingService < TournamentFixedTeamNativeService
    attr_reader :receipt, :failure
    def initialize
      @failure = LostResponse.new('Kontrolowana utrata odpowiedzi po trwałym create-bind')
    end
    def committed(receipt:)
      @receipt = receipt
      raise @failure
    end
  end

  def cold_a
    context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
    players = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
    players.each do |actor|
      execution_for(context, record, actor) do |facade|
        select_match(facade, record)
        assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
      end
    end
    provider = LosingService.new
    actual = nil
    execution_for(context, record, players.first, native_provider: provider) do |facade|
      select_match(facade, record)
      assert(facade.respond_to?(:reconcile), 'RED_FT2A_COLD: brak jawnego reconcile istniejącej intencji')
      begin
        facade.request_match
      rescue LostResponse => error
        assert(error.equal?(provider.failure), 'Ten sam wyjątek odpowiedzi')
        actual = error
      end
    end
    assert(actual, 'RED_FT2A_COLD: brak kontrolowanej utraty odpowiedzi po commit')
    state_path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
    state = JSON.parse(File.binread(state_path))
    assert_equal(1, state['native']['creates'].size)
    expected = {'pid' => Process.pid, 'record' => record, 'state' => state, 'receipt' => provider.receipt,
      'error' => {'class' => actual.class.name, 'message' => actual.message, 'cause' => actual.cause, 'backtrace' => actual.backtrace}}
    File.open(File.join(context.directory, 'cold-expected.json'), 'wx:UTF-8') { |file| file.write(JSON.pretty_generate(expected)) }
    oracle_file('cold-a.json', expected)
    puts 'GREEN A: kontrolowany koniec po utracie odpowiedzi; native core i receipt na dysku'
  end

  def cold_b
    directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'zimny-a-green-001')
    expected = JSON.parse(File.binread(File.join(directory, 'cold-expected.json')))
    assert(Process.pid != expected['pid'], 'Różne procesy A i B')
    record = expected['record']
    context = TournamentPublicServiceSupport::Context.new(directory, 'Organizator')
    context.now = 201
    player = record['evidence']['plan']['matches'].first['players'].first['username']
    result = nil
    execution_for(context, record, player, native_provider: TournamentFixedTeamNativeService.new) do |facade|
      selected = select_match(facade, record)
      result = facade.reconcile
      assert_equal(:bound, result[:state])
      assert_equal(expected['receipt']['operation_id'], result[:operation_id])
      assert_equal(selected[:native].to_h, result[:target].to_h['native'])
      execution = expected['state']['executions'].values.first
      assert_equal(execution['target'], result[:target].to_h)
    end
    state = JSON.parse(File.binread(File.join(directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')))
    assert_equal(expected['state'], state, 'Odtworzenie native core bez nowego create i mutacji biznesowej')
    oracle_file('cold-b.json', {pid: Process.pid, expected: expected, target: result[:target].to_h, state: state})
    puts 'GREEN B: exact operacja i target wyłącznie z dysku, bez nowego native create'
  end
end
