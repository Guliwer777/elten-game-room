# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
include GameRoomTest::Assertions
N=TournamentFT2B1Native
T=N::T
fixture=N.fixture('limits')
rows=[]
begin
  N.execute(fixture) do |execution|
    request=execution.selection[:request].to_h
    native=execution.selection[:native]
    actor=request['players'].first['account']
    provider=N::Provider.new
    adapter=T::FixedTeamNativeTargetAdapter.new(provider: provider,registry: N::F::REGISTRY)
    readback=adapter.budget_readback(native: native,request: request,owner: request['players'].first['username'])
    native_state=adapter.budget_native(readback)
    sizes={'options_bytes'=>JSON.generate(native.to_h['options']).bytesize,'discovery_bytes'=>JSON.generate(readback['discovery']).bytesize,
      'stack_entry_bytes'=>JSON.generate(readback['stack'].first['packet']).bytesize,'core_bytes'=>[JSON.generate(readback).bytesize,JSON.generate(native_state).bytesize].max}
    sizes.each do |key,size|
      [size-1,size].each do |limit|
        provider.advertised_limits=provider.super_limits.merge(key=>limit)
        failure=nil
        begin
          adapter.preflight!(native: native,request: request,actor: actor,state: {'creates'=>[],'cores'=>[]})
        rescue T::CoordinationContract::Blocked => error
          failure=error.code
        end
        assert_equal(limit==size ? nil : :native_limits,failure,key)
        rows << {key: key,limit: limit,size: size,reason: failure}
      end
    end
    [nil,[],{},provider.super_limits.merge('extra'=>1)].each do |limits|
      provider.advertised_limits=limits
      failure=nil
      begin
        adapter.preflight!(native: native,request: request,actor: actor)
      rescue T::Publication::Invalid => error
        failure=error.code
      end
      assert_equal(:invalid_fields,failure)
      rows << {limits: limits,reason: failure}
    end
    [false,'8192',1.0,-1].each do |value|
      provider.advertised_limits=provider.super_limits.merge('options_bytes'=>value)
      failure=nil
      begin
        adapter.preflight!(native: native,request: request,actor: actor)
      rescue T::CoordinationContract::Blocked => error
        failure=error.code
      end
      assert_equal(:native_limits,failure)
      rows << {value: value,reason: failure}
    end
    assert_equal(0,provider.opens)
  end
  # Syntetyczne węzły/głębokość nie są nazwane legalnym źródłem turnieju.
  [[{max_nodes: 2},[nil],nil],[{max_nodes: 1},[nil],:json_budget],
   [{max_depth: 1},[nil],nil],[{max_depth: 0},[nil],:json_budget]].each do |limits,value,expected|
    failure=nil
    begin
      T::Publication::Data.copy(value,**limits)
    rescue T::Publication::Invalid => error
      failure=error.code
    end
    assert_equal(expected,failure)
    rows << {synthetic: true,limits: limits,reason: failure}
  end
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'limits.json'),JSON.pretty_generate(rows))
  puts 'PASS naturalne cztery rozmiary -1/exact, nielegalne kształty/typy limits, osobne syntetyczne nodes/depth'
ensure
  N.close(fixture)
end
