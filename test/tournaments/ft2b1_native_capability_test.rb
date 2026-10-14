# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
include GameRoomTest::Assertions
N=TournamentFT2B1Native
T=N::T
fixture=N.fixture('tx')
begin
  N.execute(fixture) do |execution|
    request=execution.selection[:request].to_h
    native=execution.selection[:native]
    [nil,Object.new,Struct.new(:program,:metadata,:dump).new(nil,nil,nil)].each do |transaction|
      provider=N::Provider.new
      provider.define_singleton_method(:open) { |**_| transaction }
      adapter=T::FixedTeamNativeTargetAdapter.new(provider: provider,registry: N::F::REGISTRY)
      failure=nil
      (_,calls)=N.observed do
        begin
          adapter.create(state: {'creates'=>[],'cores'=>[]},native: native,request: request,actor: request['players'].first['account'])
        rescue Exception => error
          failure=error
        end
      end
      assert_equal(T::CoordinationContract::Blocked,failure.class,'Niepełna capability transakcji nie daje kontrolowanej odmowy')
      assert_equal(:coordination_unavailable,failure.code)
      assert_equal([],calls)
    end
  end
  puts 'PASS niepełny uchwyt transakcji odmawia przed Transport/create bez fallbacku'
ensure
  N.close(fixture)
end
