# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
require EltenTestHost.file('src/eapi/server_clock.rb')
include GameRoomTest::Assertions
N=TournamentFT2B1Native
T=N::T
samples=[]
[[0,0,1,1],[0,1,0,1]].each_with_index do |template, ti|
  [1,2].each do |leg|
    fixture=N.fixture("t#{ti}l#{leg}",template: template)
    begin
      index=fixture[:record]['evidence']['plan']['matches'].index { |m| m['leg']==leg }
      match=fixture[:record]['evidence']['plan']['matches'][index]
      N.ready(fixture,index)
      N.execute(fixture,index) do |execution|
        result=execution.request_match
        assert_equal(:bound,result[:state],result.inspect)
        target=result[:target].to_h
        assert_equal(template,target['native']['options']['team_seats'])
        assert_equal(match['players'].map { |p| p['username'] },target['native']['players'])
        assert_equal(target['native']['players'],target['native']['options']['team_players'])
        assert_equal(false,execution.selection[:request].to_h['options'].key?('team_players'))
        assert_equal(true,target['native']['options'].values.any? { |v| v.equal?(false) })
        path=execution.instance_variable_get(:@storage).path
        document=JSON.parse(File.binread(path))
        row=document['executions'].values.find { |r| r['request']['match_id']==match['match_id'] }
        core=document['native']['cores'].first
        assert_equal(1,document['native']['creates'].size)
        assert_equal(1,core['entries'].size)
        assert_equal('room_created',core['entries'].first['packet']['kind'])
        assert_equal({},core['invitations'])
        assert_equal(false,core['closed'])
        assert_equal(1,core['participants'].size)
        assert_equal(nil,target['readback']['game_instance'])
        assert_equal(target,execution.reconcile[:target].to_h)
        assert_equal(target,T::FixedTeamBoundTarget.build(record: fixture[:record],response: row['operations']['create_bind'],readback: target['readback'],registry: N::F::REGISTRY).to_h)
        samples << {record: fixture[:record],target: target,response: row['operations']['create_bind'],core: core,request: execution.selection[:request].to_h}
      end
    ensure
      N.close(fixture)
    end
  end
end
samples.each_slice(2) do |first,second|
  template=first[:target]['native']['options']['team_seats']
  sides=->(sample) { [0,1].map { |side| sample[:target]['native']['players'].each_with_index.filter_map { |p,i| p if template[i]==side } } }
  assert_equal(sides.call(first).reverse,sides.call(second),'Leg2 nie zamienia całych ekip')
end
first,other=samples.values_at(0,2)
negatives={
  'inny-legalny-uuid' => other[:target]['readback'],
  'inne-legalne-options' => T::CoordinationContract.copy(first[:target]['readback']),
  'inna-legalna-metadata' => T::CoordinationContract.copy(first[:target]['readback'])
}
negatives['inne-legalne-options']['table']['game_options']=other[:target]['readback']['table']['game_options']
negatives['inna-legalna-metadata']['metadata']=other[:target]['readback']['metadata']
gates=[]
negatives.each do |name,readback|
  failure=nil
  begin
    T::FixedTeamBoundTarget.build(record: first[:record],response: first[:response],readback: readback,registry: N::F::REGISTRY)
  rescue T::CoordinationContract::Blocked => error
    failure=error.code
  end
  assert_equal(:native_target_mismatch,failure,name)
  gates << {name: name,reason: failure,readback: readback}
end
File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'exact.json'),JSON.pretty_generate({samples: samples,negatives: gates}))
puts 'PASS legalne oba template i leg1/2, pełny core/binding/receipt; trzy podmiany dochodzą do exactgate'
