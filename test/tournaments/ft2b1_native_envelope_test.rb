# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
include GameRoomTest::Assertions
N=TournamentFT2B1Native
T=N::T
fixture=N.fixture('env')
rows=[]
begin
  N.ready(fixture,0)
  N.execute(fixture) do |execution|
    port=execution.send(:coordination_port)
    request=execution.selection[:request].to_h
    snapshot=port.snapshot(request: request)
    operation=T::CoordinationContract.operation(kind: 'reserve',request: request,actor: request['players'].first['account'],operation_id: SecureRandom.uuid,
      preconditions: {'expected_revision'=>snapshot['resource_revision'],'ready_versions'=>snapshot['ready'].transform_values { |r| r['revision'] },'window'=>request['window'],'grant'=>nil})
    storage=execution.instance_variable_get(:@storage)
    before=File.binread(storage.path)
    document=JSON.parse(before)
    row=document['executions'].values.first
    response=port.send(:budget_response,operation,row)
    bytes=JSON.generate(response).bytesize
    [bytes-1,bytes].each do |limit|
      failure=nil
      begin
        port.preflight_operation(operation: operation,max_bytes: limit)
      rescue T::CoordinationContract::Blocked => error
        failure=error.code
      end
      assert_equal(limit==bytes ? nil : :payload_too_large,failure)
      assert_equal(before,File.binread(storage.path))
      rows << {gate: 'preflight_operation pełnego receipt/envelope',limit: limit,bytes: bytes,reason: failure,response: response}
    end
    original=port.method(:negotiate)
    port.define_singleton_method(:negotiate) { |**args| original.call(**args).merge('max_bytes'=>bytes-1) }
    (result,calls)=N.observed { execution.request_match }
    assert_equal(:payload_too_large,result[:reason],result.inspect)
    assert_equal([],calls)
    assert_equal(before,File.binread(storage.path))
    rows << {gate: 'kompozycja niższy limit envelope',reason: result[:reason],calls: calls}
  end
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'envelope.json'),JSON.pretty_generate(rows))
  puts 'PASS pełny legalny envelope: naturalne bytes-1/bytes i niższy negocjowany limit przed reserve/create'
ensure
  N.close(fixture)
end
