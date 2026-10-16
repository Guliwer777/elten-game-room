# encoding: UTF-8
require_relative '../support/ft2_runtime_cold'
include FT2RuntimeCold
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
all_ready(context, record)
actor = record['evidence']['plan']['matches'].first['players'].first['username']
execution_for(context, record, actor, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  assert_equal(:bound, facade.request_match[:state])
end
rows = []
%i[actor backend session lease program runtime].each do |event|
  before = File.binread(state_path(context))
  resources = nil; row = nil
  runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade, session, program, entry|
    select_match(facade, record)
    runtime = program.class.app_runtime
    resources = [program.managed_resources, runtime.managed_resources, session]
    assert_equal([2, 2], resources.first(2).map(&:size), 'Rzeczywiste wpisy obu EntryContext w Registry')
    assert_equal([2, 1], [session.actor_events.listener_count, session.backend_events.listener_count])
    fired = false
    trace = TracePoint.new(:return) do |point|
      next unless !fired && point.defined_class == T::LocalFixedTeamCoordinationPort && point.method_id == :lookup_target
      fired = true
      case event
      when :actor
        session.choose_actor('InnaOsoba'); session.choose_actor(actor)
      when :backend
        original = session.backend_events.snapshot[:value]
        session.change_backend('inny-backend'); session.change_backend(original)
      when :session then session.close
      when :lease then entry.close
      when :program then program.finalize
      when :runtime then runtime.close
      end
    end
    effects do |calls|
      trace.enable(target_thread: nil)
      begin
        worker = Thread.new { outcome { facade.reconcile } }
        result = worker.value
        assert(!worker.alive?)
      ensure
        trace.disable
      end
      assert(fired)
      assert_equal(:blocked, result[:state], 'Stary worker nie publikuje wyniku')
      assert_equal(:context_changed, result[:reason])
      ready = outcome { facade.declare(availability: 'ready', expected_revision: 1) }
      fresh = outcome { facade.request_match }
      assert_equal(:blocked, ready[:state]); assert_equal(:blocked, fresh[:state])
      assert_equal([], calls)
      row = {event: event, result: result, ready: ready, fresh: fresh, calls: calls, worker_joined: true}
    end
  end
  assert(before == File.binread(state_path(context)))
  assert_equal([0, 0], resources.first(2).map(&:size))
  assert(resources.first(2).all?(&:closed?))
  assert_equal([0, 0], [resources.last.actor_events.listener_count, resources.last.backend_events.listener_count])
  row[:registry_after] = resources.first(2).map(&:size)
  row[:listeners_after] = [resources.last.actor_events.listener_count, resources.last.backend_events.listener_count]
  rows << row
end
oracle_file('lifecycle.json', rows)
puts 'GREEN: actual actor/backend ABA, session/lease/program/runtime; worker odcięty, Registry/listeners puste'
