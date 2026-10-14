# encoding: UTF-8
require_relative '../support/ft2_compatibility_boundary'
include FT2CompatibilityBoundary
trace = FT2CompatibilityTrace.new
begin
  expected = JSON.parse(File.binread(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'boundary-final-expected.json')))
  assert(expected['pid'] != Process.pid, 'Osobny zimny proces B')
  actual = expected['outcomes'].each_with_index.map do |row, index|
    context = TournamentPublicServiceSupport::Context.new(row['directory'], 'Organizator')
    context.now = 201
    record = row['record']
    assert_equal(row['files_hex'], disk_hex(context.directory), 'Zimny B dostaje exact pliki A')
    actor = record['evidence']['plan']['matches'].first['players'].first['username']
    result = nil
    execution_for(context, record, actor, native_provider: TournamentFixedTeamNativeService.new) do |facade|
      select_match(facade, record)
      trace.during("zimny-reconcile-#{index}") { result = trace.worker { facade.reconcile } }
      assert_equal(:bound, result[:state])
      assert_equal(row['target'], result[:target].to_h)
      trace.during("ponowny-request-#{index}") { result = trace.worker { facade.request_match } }
      assert_equal(:bound, result[:state])
      assert_equal(row['target'], result[:target].to_h)
    end
    target = result[:target].to_h
    state = JSON.parse(File.binread(state_path(context)))
    assert_equal(row['state'], state, 'Dokładny trwały native core oraz wszystkie operation IDs')
    check_no_start(state, target)
    consumer = native_consumer(target, record)
    before = disk_hex(context.directory)
    denials = deny_entry(context, record, result, trace: trace)
    assert_equal(before, disk_hex(context.directory), 'Guard/AcceptInvitation bez zapisów')
    {'target' => target, 'state' => state, 'consumer' => consumer, 'denials' => denials, 'files_hex' => disk_hex(context.directory)}
  end
  trace.check_empty(trace.rows)
  assert_equal([], trace.rows.select { |r| r['method'] == 'create_room' }, 'Zimny request/reconcile nie tworzy ponownie')
  oracle_file('boundary-b.json', {pid: Process.pid, expected: expected, actual: actual, trace: trace.rows, workers: trace.workers})
  puts 'GREEN B: cold reconcile/request oraz rzeczywiste odmowy zgody, bez kolejnego create lub Start'
ensure
  trace.close
  oracle_file('boundary-b-trace.json', trace.rows)
end
