# encoding: UTF-8
require_relative '../support/ft2_compatibility_boundary'
include FT2CompatibilityBoundary
trace = FT2CompatibilityTrace.new
begin
  outcomes = []
  [[0, 0, 1, 1], [0, 1, 0, 1]].each_with_index do |template, index|
    name = File.basename(ENV.fetch('ENTRY_EVIDENCE')) + "-#{index}"
    context, record = execution_fixture(name, template: template)
    players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
    ready = []
    players.first(3).each do |actor|
      execution_for(context, record, actor) do |facade|
        select_match(facade, record)
        trace.during("ready-#{index}") { ready << facade.declare(availability: 'ready', expected_revision: 0) }
        assert_equal(:confirmed, ready.last[:state])
      end
    end
    refusal = nil
    execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
      select_match(facade, record)
      trace.during("trzy-ready-#{index}") { refusal = facade.request_match }
      assert_equal(:not_all_ready, refusal[:reason])
    end
    state_three = JSON.parse(File.binread(state_path(context)))
    assert_equal([], state_three['native']['creates'])
    assert_equal({}, state_three['busy'])
    execution_for(context, record, players.last) do |facade|
      select_match(facade, record)
      trace.during("czwarty-ready-#{index}") { ready << facade.declare(availability: 'ready', expected_revision: 0) }
      assert_equal(:confirmed, ready.last[:state])
    end
    provider = index == 0 ? TournamentFixedTeamNativeService.new : LosingProvider.new
    result = nil
    exception = nil
    execution_for(context, record, players.first, native_provider: provider) do |facade|
      selected = select_match(facade, record)
      if index == 0
        trace.during('nowy-request') { result = facade.request_match }
      else
        error = assert_raises(ResponseLost) { trace.during('request-exception') { facade.request_match } }
        assert(error.equal?(provider.failure), 'Dokładny primary po skutku')
        exception = {'class' => error.class.name, 'message' => error.message, 'cause' => error.cause, 'backtrace' => error.backtrace}
        trace.during('reconcile-po-exception') { result = facade.reconcile }
      end
      assert_equal(:bound, result[:state], 'Rzeczywisty CoordinationService, nie atrapa :bound')
      assert_equal(selected[:native].to_h, result[:target].to_h['native'])
      previous = result[:target].to_h
      trace.during("reconcile-cieply-#{index}") { result = facade.reconcile }
      assert_equal(previous, result[:target].to_h)
    end
    target = result[:target].to_h
    state = JSON.parse(File.binread(state_path(context)))
    check_no_start(state, target)
    consumer = native_consumer(target, record)
    before = disk_hex(context.directory)
    denials = deny_entry(context, record, result, trace: trace)
    after = disk_hex(context.directory)
    assert_equal(before, after, 'Odmowy nie zapisują zgody, wejścia ani migracji')
    check_no_start(JSON.parse(File.binread(state_path(context))), target)
    outcomes << {'directory' => context.directory, 'record' => record, 'target' => target, 'state' => state,
      'state_three' => state_three, 'three_refused' => refusal, 'ready' => ready, 'exception' => exception,
      'consumer' => consumer, 'denials' => denials, 'files_hex' => after}
  end
  trace.check_empty(trace.rows)
  methods = trace.rows.map { |r| r['method'] }.uniq
  %w[negotiate snapshot claim reserve lookup create_bind lookup_target create_room].each do |name|
    assert(methods.include?(name), "Nieosiągnięta rzeczywista bramka #{name}")
  end
  expected = {'pid' => Process.pid, 'outcomes' => outcomes}
  File.open(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'boundary-final-expected.json'), 'wx:UTF-8') { |f| f.write(JSON.pretty_generate(expected)) }
  oracle_file('boundary-a.json', expected.merge('trace' => trace.rows))
  puts 'GREEN A: dwa szablony, realne 4ready/Service/native; request/reconcile/exception bez zgody i Start'
ensure
  trace.close
  oracle_file('boundary-a-trace.json', trace.rows)
end
