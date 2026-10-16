# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
require EltenTestHost.file('src/eapi/server_clock.rb')
include GameRoomTest::Assertions
N=TournamentFT2B1Native
assert_equal(nil,EltenAPI::ServerClock.now)
mode=ARGV.fetch(0)
shared=File.join(ENV.fetch('FT2_SCRATCH'),'shared',"native-cold-#{ARGV[1] || 'first'}.json")
clock_calls=[]
trace=TracePoint.new(:call) do |event|
  clock_calls << event.method_id if event.path.tr('\\','/').end_with?('/server_clock.rb')
end
trace.enable(target_thread: nil)
fixture=nil
begin
  if mode=='A'
    fixture=N.fixture('cold')
    N.ready(fixture,0)
    N.execute(fixture) do |execution|
      result=execution.request_match
      assert_equal(:bound,result[:state])
      state=JSON.parse(File.binread(execution.instance_variable_get(:@storage).path))
      core=state['native']['cores'].first
      assert_equal(true,core['entries'].first['created_at'].positive?)
      assert_equal(1,state['native']['creates'].size)
      File.binwrite(shared,JSON.generate({fixture: fixture.reject { |key,_| key==:program },target: result[:target].to_h,state: state,pid: Process.pid}))
    end
  elsif mode=='B'
    saved=JSON.parse(File.binread(shared))
    fixture=saved['fixture'].transform_keys(&:to_sym)
    fixture[:program]=TournamentEntryContextTest::Program.new(File.dirname(fixture[:sandbox]))
    assert_equal(false,saved['pid']==Process.pid)
    before=N.bytes(fixture[:sandbox])
    (result,calls)=N.observed { N.execute(fixture) { |e| e.reconcile } }
    assert_equal(:bound,result[:state],result.inspect)
    assert_equal(saved['target'],result[:target].to_h)
    assert_equal([],calls)
    assert_equal(before,N.bytes(fixture[:sandbox]))
    N.execute(fixture) do |execution|
      assert_equal(saved['state'],JSON.parse(File.binread(execution.instance_variable_get(:@storage).path)))
    end
  else
    raise 'Nieznana faza'
  end
  assert_equal([],clock_calls,'Lokalna ścieżka uruchomiła hostowy clock/fallback')
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'cold.json'),JSON.pretty_generate({mode: mode,pid: Process.pid,clock_calls: clock_calls}))
  puts "PASS cold #{mode}: produkcyjny native i pełny ACK bez hostowego clock"
ensure
  trace.disable
  N.close(fixture) if fixture
end
