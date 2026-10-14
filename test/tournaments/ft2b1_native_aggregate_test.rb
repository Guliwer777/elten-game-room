# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
include GameRoomTest::Assertions
N=TournamentFT2B1Native
T=N::T
fixture=N.fixture('a')
rows=[]
begin
  N.ready(fixture,0)
  N.execute(fixture) { |e| assert_equal(:bound,e.request_match[:state]) }
  N.execute(fixture,1) do |execution|
    request=execution.selection[:request].to_h
    native=execution.selection[:native]
    owner=request['players'].first
    provider=N::Provider.new
    adapter=T::FixedTeamNativeTargetAdapter.new(provider: provider,registry: N::F::REGISTRY)
    state=JSON.parse(File.binread(execution.instance_variable_get(:@storage).path))['native']
    projected=adapter.budget_readback(native: native,request: request,owner: owner['username'])
    single=adapter.budget_native(projected)
    aggregate=single.to_h { |key,values| [key,state.fetch(key)+values] }
    size=JSON.generate(aggregate).bytesize
    # Dokładna naturalna granica na dwóch realnych legalnych celach, nie sztuczne MAX.
    [size-1,size].each do |limit|
      provider.advertised_limits['core_bytes']=limit
      error=nil
      begin
        adapter.preflight!(native: native,request: request,actor: owner['account'],state: state)
      rescue T::CoordinationContract::Blocked => failure
        error=failure.code
      end
      assert_equal(limit==size ? nil : :native_limits,error)
      rows << {kind: 'native-aggregate',bytes: size,limit: limit,reason: error}
    end
    provider.advertised_limits['core_bytes']=size-1
    before=N.bytes(fixture[:sandbox])
    (result,calls)=N.observed do
      N.execute(fixture,1,provider: provider) { |e| e.request_match }
    end
    assert_equal(:native_limits,result[:reason])
    assert_equal([],calls)
    assert_equal(before,N.bytes(fixture[:sandbox]))
    rows << {kind: 'composition-aggregate',reason: result[:reason],calls: calls}
    # Syntetyczny walidator ma osobną etykietę i nie udaje legalnego planu.
    [32,33].each do |bytes|
      value='x'*(bytes-2)
      error=nil
      begin
        T::Publication::Data.copy(value,max_bytes: 32)
      rescue T::Publication::Invalid => failure
        error=failure.code
      end
      assert_equal(bytes==32 ? nil : :json_budget,error)
      rows << {kind: 'synthetic-json-bytes',bytes: bytes,reason: error}
    end
  end
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'limits.json'),JSON.pretty_generate(rows))
  puts 'PASS naturalny aggregate core limit-1/limit i kompozycja przed reserve/create; osobny syntetyczny JSON'
ensure
  N.close(fixture)
end
