# encoding: UTF-8
require_relative '../support/ft2_fencing_probe'
include FT2FencingProbe
# Błąd nowego odczytu końcowego nie staje się blocked/unknown i nie kasuje skutku.
[IOError.new('Błąd odczytu po commit'), T::CoordinationContract::Blocked.new(:stale_coordinator),
 T::Publication::Invalid.new(:record_mismatch)].each_with_index do |primary, index|
  context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + "-#{index}")
  all_ready(context, record)
  actor = record['evidence']['plan']['matches'].first['players'].first['username']
  cause = RuntimeError.new('Bezpośrednia przyczyna próby')
  primary.set_backtrace(["#{__FILE__}:#{__LINE__}:in 'kontrolowana_granica'"])
  expected_backtrace = primary.backtrace.dup
  inside = false; fired = false; caught = nil; saved = nil; late = []
  runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
    select_match(facade, record)
    trace = TracePoint.new(:call, :return) do |event|
      if event.defined_class == T::LocalFixedTeamCoordinationPort && event.method_id == :validate_epoch!
        inside = event.event == :call
      end
      next unless inside && !fired && event.event == :return &&
        event.defined_class == T::LocalFixedTeamExecutionStorage && event.method_id == :read_document
      saved = durable_map(context)
      fired = true
      raise primary, cause: cause
    end
    count_effects(late, after_child: -> { fired }) do
      begin
        trace.enable(target_thread: nil)
        worker_result("primary-#{index}") do
          begin
            facade.request_match
          rescue Exception => error
            caught = error
          end
        end
      ensure
        trace.disable
      end
    end
    assert(fired && caught.equal?(primary), 'Dokładny obiekt primary nowej granicy')
    assert(caught.cause.equal?(cause), 'Dokładny bezpośredni cause')
    assert_equal(expected_backtrace, caught.backtrace)
    assert_equal([], late)
    assert_equal(saved, durable_map(context))
  end
  # Nowa instancja potwierdza również zwolnienie storage lock po primary.
  recovered = nil
  runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
    historical_select(facade, record)
    recovered = facade.reconcile
  end
  assert_equal(:bound, recovered[:state])
  assert_equal(1, state(context)['native']['creates'].size)
  assert_equal(saved, durable_map(context))
  oracle_file("primary-#{index}.json", {primary: primary.class.name, same_object: caught.equal?(primary),
    same_cause: caught.cause.equal?(cause), expected_backtrace: expected_backtrace, actual_backtrace: caught.backtrace,
    late: late, before: saved, after: durable_map(context), recovered: recovered.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v }})
end
puts 'GREEN: primary/cause/backtrace zachowane po commit, bez efektów; lock zwolniony i exact readback'
