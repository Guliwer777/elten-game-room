# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
calls = []
trace = TracePoint.new(:call) do |event|
  calls << event.method_id if %i[reserve create_bind create_room create].include?(event.method_id)
end
begin
  trace.enable(target_thread: nil)
  deadline = fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes']
  [nil, fixture[:now], deadline + 1].each do |value|
    F.with_execution(fixture, 'Ala', expires_at: value) do |execution|
      F.select_execution(execution, fixture[:record])
      result = execution.request_match
      assert_equal(:blocked, result[:state])
      assert_equal(value.nil? ? :technical_deadline_required : :invalid_technical_deadline, result[:reason])
      assert_equal(nil, result[:operation_id])
    end
  end
  assert_equal([], calls)
  puts 'PASS brak/przeszły/poza oknem termin: konkretna odmowa, zero reserve/create'
ensure
  trace.disable; fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
