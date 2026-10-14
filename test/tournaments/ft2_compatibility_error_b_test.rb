# encoding: UTF-8
require_relative '../support/ft2_compatibility_boundary'
include FT2CompatibilityBoundary
trace = FT2CompatibilityTrace.new
begin
  expected = JSON.parse(File.binread(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'error-expected.json')))
  assert(expected['pid'] != Process.pid, 'Nowy PID po zakończonym A')
  context = TournamentPublicServiceSupport::Context.new(expected['directory'], 'Organizator')
  context.now = 201
  record = expected['record']
  assert_equal(expected['files_hex'], disk_hex(context.directory), 'Tylko pełne pliki A')
  actor = record['evidence']['plan']['matches'].first['players'].first['username']
  result = nil
  execution_for(context, record, actor, native_provider: TournamentFixedTeamNativeService.new) do |facade|
    select_match(facade, record)
    trace.during('zimne-reconcile-po-exception') { result = trace.worker { facade.reconcile } }
    assert_equal(:bound, result[:state])
    assert_equal(expected['receipt']['operation_id'], result[:operation_id])
    assert_equal(expected['target'], result[:target].to_h)
  end
  state = JSON.parse(File.binread(state_path(context)))
  assert_equal(expected['state'], state, 'Native core/state byte-semantycznie bez zmian')
  check_no_start(state, result[:target].to_h)
  before = disk_hex(context.directory)
  denials = deny_entry(context, record, result, trace: trace)
  assert_equal(before, disk_hex(context.directory), 'Odzyskanie nie nadaje własnej zgody/wejścia')
  trace.check_empty(trace.rows)
  assert_equal([], trace.rows.select { |r| r['method'] == 'create_room' }, 'Brak powtórnego create')
  oracle_file('error-b.json', {pid: Process.pid, expected: expected, target: result[:target].to_h, state: state,
    denials: denials, files_hex: disk_hex(context.directory), trace: trace.rows, workers: trace.workers})
  puts 'GREEN B-error: zimne odzyskanie tej samej operacji, realny guard nadal odmawia K06'
ensure
  trace.close
  oracle_file('error-b-trace.json', trace.rows)
end
