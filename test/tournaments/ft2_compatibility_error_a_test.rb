# encoding: UTF-8
require_relative '../support/ft2_compatibility_boundary'
include FT2CompatibilityBoundary
trace = FT2CompatibilityTrace.new
begin
  context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
  players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
  players.each do |actor|
    execution_for(context, record, actor) do |facade|
      select_match(facade, record)
      assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  provider = LosingProvider.new
  error = nil
  execution_for(context, record, players.first, native_provider: provider) do |facade|
    select_match(facade, record)
    error = assert_raises(ResponseLost) { trace.during('request-utrata-odpowiedzi') { facade.request_match } }
    assert(error.equal?(provider.failure), 'Ten sam primary, nie odmowa walidacji')
  end
  state = JSON.parse(File.binread(state_path(context)))
  target = state['executions'].values.first['target']
  check_no_start(state, target)
  trace.check_empty(trace.rows)
  expected = {'pid' => Process.pid, 'directory' => context.directory, 'record' => record, 'state' => state,
    'target' => target, 'receipt' => provider.receipt, 'files_hex' => disk_hex(context.directory),
    'error' => {'class' => error.class.name, 'message' => error.message, 'cause' => error.cause, 'backtrace' => error.backtrace}}
  File.open(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'error-expected.json'), 'wx:UTF-8') { |f| f.write(JSON.pretty_generate(expected)) }
  oracle_file('error-a.json', expected.merge('trace' => trace.rows))
  puts 'GREEN A-error: koniec bez reconcile po utracie odpowiedzi; brak invite/consent/entered/Start'
ensure
  trace.close
  oracle_file('error-a-trace.json', trace.rows)
end
