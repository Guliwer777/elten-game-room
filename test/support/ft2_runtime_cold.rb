# encoding: UTF-8
require_relative 'ft2_runtime_support'
module FT2RuntimeCold
  include FT2RuntimeSupport
  MODES = %w[history withdrawn revoked expired before_commit].freeze
  class BeforeCommit < TournamentFixedTeamNativeService
    attr_reader :failure
    def initialize
      @failure = IOError.new('Jawna awaria lokalnego providera przed wspólnym commit')
    end
    def open(state:, owner:)
      Transaction.new(state, owner, @failure)
    end
    class Transaction < TournamentFixedTeamNativeService::Transaction
      def initialize(state, owner, failure)
        super(state, owner)
        @failure = failure
      end
      def dump
        value = super
        raise @failure unless value['creates'].empty?
        value
      end
    end
  end
  def runtime_execution(context, record, actor, provider:, now: nil)
    actor_backend(context, actor) do |backend, authority, directory, session, program, entry|
      window = record['evidence']['plan']['matches'].first['windows'].first
      facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
        source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
        clock: -> { now || window['opens'] + 1 }, policy_ref: 'jawna-polityka-proby-ft2a', expires_at: window['closes'] - 1)
      facade.native_provider = provider
      yield facade, session, program, entry
    end
  end
  def effects
    calls = []
    trace = TracePoint.new(:call) do |event|
      relevant = (event.defined_class == T::LocalFixedTeamCoordinationPort && %i[reserve create_bind].include?(event.method_id)) ||
        (event.defined_class == T::LocalFixedTeamReadinessPort && event.method_id == :store) ||
        (event.defined_class == GameRoomTransport && %i[create_room start_game invite].include?(event.method_id))
      calls << {class: event.defined_class.name, method: event.method_id, thread: Thread.current.object_id} if relevant
    end
    trace.enable(target_thread: nil)
    yield calls
  ensure
    trace&.disable
  end
  def cold_runtime_a
    MODES.each do |mode|
      context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + '-' + mode)
      all_ready(context, record)
      player = record['evidence']['plan']['matches'].first['players'].first['username']
      provider = mode == 'before_commit' ? BeforeCommit.new : TournamentFixedTeamExecutionProcess::LosingService.new
      caught = nil
      calls = nil
      effects do |observed|
        calls = observed
        runtime_execution(context, record, player, provider: provider) do |facade|
          select_match(facade, record)
          begin
            facade.request_match
          rescue IOError, TournamentFixedTeamExecutionProcess::LostResponse => error
            assert(error.equal?(provider.failure))
            caught = {class: error.class.name, message: error.message, cause: error.cause, backtrace: error.backtrace}
          end
        end
      end
      assert(caught, 'Kontrolowana awaria musi faktycznie wystąpić')
      committed = state(context)
      assert_equal(1, calls.count { |call| call[:method] == :create_room })
      assert_equal(mode == 'before_commit' ? 0 : 1, committed['native']['creates'].size)
      case mode
      when 'history' then observe_change(context, record)
      when 'withdrawn'
        runtime_execution(context, record, player, provider: TournamentFixedTeamNativeService.new) do |facade|
          select_match(facade, record)
          assert_equal(:confirmed, facade.declare(availability: 'withdrawn', expected_revision: 1)[:state])
        end
      when 'revoked'
        runtime_execution(context, record, player, provider: TournamentFixedTeamNativeService.new) do |facade|
          select_match(facade, record)
          epoch = facade.coordinator_epoch
          assert_equal(epoch + 1, facade.revoke_coordinator(expected_epoch: epoch))
        end
      end
      expected = {pid: Process.pid, mode: mode, record: record, committed: committed, state: state(context), calls: calls, failure: caught}
      File.open(File.join(context.directory, 'cold-expected.json'), 'wx:UTF-8') { |f| f.write(JSON.pretty_generate(expected)) }
      oracle_file("cold-a-#{mode}.json", expected)
      puts "A: #{mode}, rzeczywisty create i zakończenie bez retry"
    end
  end
  def cold_runtime_b
    MODES.each do |mode|
      name = File.basename(ENV.fetch('ENTRY_EVIDENCE')).sub(/-b$/, '-a') + '-' + mode
      directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', name)
      expected = JSON.parse(File.binread(File.join(directory, 'cold-expected.json')))
      assert(Process.pid != expected['pid'])
      context = TournamentPublicServiceSupport::Context.new(directory, 'Organizator'); context.now = 201
      record = expected['record']; player = record['evidence']['plan']['matches'].first['players'].first['username']
      now = mode == 'expired' ? record['evidence']['plan']['matches'].first['windows'].first['closes'] + 1 : nil
      before = File.binread(state_path(context))
      actual = nil; repeated = nil; calls = nil
      effects do |observed|
        calls = observed
        runtime_execution(context, record, player, provider: TournamentFixedTeamNativeService.new, now: now) do |facade|
          historical_select(facade, record)
          actual = outcome { facade.reconcile }
          repeated = outcome { facade.request_match }
        end
      end
      after = File.binread(state_path(context))
      oracle_file("cold-b-#{mode}.json", {pid: Process.pid, expected: expected, actual: actual.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v },
        repeated: repeated.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v }, calls: calls, disk_equal: before == after, state: state(context)})
      invalidated = %w[withdrawn revoked].include?(mode)
      expected_state = invalidated ? :blocked : (mode == 'before_commit' ? :unknown : :bound)
      assert_equal(expected_state, actual[:state], 'Cold readback must respect revoked authorization')
      assert_equal([], calls, 'RED_FT2A_RUNTIME_COLD: cold nie może ponowić żadnego skutku')
      assert(before == after, 'B nie zmienia wspólnego state')
      if mode == 'before_commit'
        assert_equal(:unknown, repeated[:state])
        assert_equal(actual[:operation_id], repeated[:operation_id])
        assert(actual[:operation_id], 'Zachowany oryginalny klucz attempted')
      else
        execution = expected['committed']['executions'].values.first
        assert_equal(execution['operations']['create_bind']['operation_id'], actual[:operation_id])
        if invalidated
          assert_equal(:stale_grant, actual[:reason])
          assert_equal(:blocked, repeated[:state])
          assert_equal(:stale_grant, repeated[:reason])
          assert_equal(actual[:operation_id], repeated[:operation_id])
        else
          assert_equal(execution['target'], actual[:target].to_h)
        end
        assert_equal(expected['committed']['native'], state(context)['native'])
        assert_equal(1, state(context)['native']['creates'].size)
      end
      puts "B: #{mode}, exact readback bez nowego create"
    end
  end
end
