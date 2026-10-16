# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
require EltenTestHost.file('src/eapi/server_clock.rb')
include GameRoomTest::Assertions
N = TournamentFT2B1Native
T = N::T
rows=[]
[false, true].each do |healthy|
  fixture=N.fixture(healthy ? 'h' : 'e')
  begin
    N.ready(fixture,0) if healthy
    cases=[['brak',nil],['niepełny',Object.new]]
    [nil, false, '1', 1.0, 2].each do |version|
      p=N::Provider.new;p.version=version;cases << ["wersja-#{version.inspect}",p]
    end
    cases.each do |name,provider|
      before=N.bytes(fixture[:sandbox])
      (result,calls)=N.observed { N.execute(fixture,provider: provider) { |execution| execution.request_match } }
      assert_equal(:coordination_unavailable,result[:reason],name)
      assert_equal([],calls,name)
      assert_equal(before,N.bytes(fixture[:sandbox]),name)
      rows << {healthy: healthy,case: name,reason: result[:reason],calls: calls}
    end
    %w[options_bytes discovery_bytes stack_entry_bytes core_bytes].each do |key|
      [0,1].each do |limit|
        provider=N::Provider.new;provider.advertised_limits[key]=limit
        before=N.bytes(fixture[:sandbox])
        (result,calls)=N.observed { N.execute(fixture,provider: provider) { |execution| execution.request_match } }
        assert_equal(:native_limits,result[:reason],key)
        assert_equal([],calls,key)
        assert_equal(0,provider.opens,key)
        assert_equal(before,N.bytes(fixture[:sandbox]),key)
        rows << {healthy: healthy,case: key,limit: limit,reason: result[:reason],calls: calls}
      end
    end
    if healthy
      (result,calls)=N.observed { N.execute(fixture) { |execution| execution.request_match } }
      assert_equal(:bound,result[:state],result.inspect)
      assert_equal(1,calls.count { |owner,method| owner==T::LocalFixedTeamNativeEndpoint.to_s && method==:create })
      rows << {healthy: true,case: 'kontrola-dodatnia',calls: calls,target: result[:target].to_h}
    end
  ensure
    N.close(fixture)
  end
end
File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'gates.json'),JSON.pretty_generate(rows))
puts 'PASS brak/capability/niższe limity pusty i zdrowy magazyn; zero reserve/create oraz dodatni realny create'
