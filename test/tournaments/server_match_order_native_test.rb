# encoding: UTF-8
if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/assertions'
require_relative '../support/tournament_native'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/server_schedule_overview'
include GameRoomTest::Assertions
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})

[false,true].each do |teams|
  [:participant,:playing_organiser,:observer].each do |role|
    program=TournamentEntryContextTest::Program.new
    actor=role==:observer ? 'spectator' : 'ALPHA'
    author=role==:playing_organiser ? 'alpha' : 'organiser'
    revision=0
    program.class.define_singleton_method(:tournament_view_revision){|*|revision}
    workspace=Object.new
    workspace.define_singleton_method(:actor){actor}
    owner=T::Dialogs::Owner.new(-> {actor},->(message){raise message})
    row=->(id,names,leg=1){{'match_id'=>id,'players'=>names,'leg'=>leg}}
    matches=[
      row.call('other',%w[zeta theta]),
      row.call('own-done',%w[alpha beta]),
      row.call('own-return',%w[alpha gamma],2),
      row.call('other-return',%w[zeta theta],2),
      row.call('own',%w[alpha gamma]),
      row.call('other-done',%w[delta epsilon]),
      row.call('own-second',%w[alpha delta])
    ]
    candidate={'format'=>'round_robin','schedule_id'=>'phase','matches'=>matches}
    if teams
      units=matches.flat_map{|match|match['players']}.uniq.map{|name|{'unit_id'=>name+'-team','accounts'=>[name,name+'-partner']}}
      candidate['membership']={'units'=>units}
      matches.each do |match|
        match['unit_ids']=match['players'].map{|name|name+'-team'}
        match['players']=match['players'].flat_map{|name|[name,name+'-partner']}
      end
    end
    before=Marshal.dump(candidate)
    receipt=->(id){matches.find{|match|match['match_id']==id}.slice('match_id','leg').merge('summary'=>{'draw'=>true,'winners'=>[]})}
    completed=%w[own-done other-done].map{|id|receipt.call(id)}
    program.define_singleton_method(:ordinary_tournament_overview) do |*_,**|
      {'candidate'=>candidate,'storage'=>'confirmed','results'=>{'results'=>completed,'standings'=>[]}}
    end
    screen=T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,
      publication:{'title'=>'Ordering','__insertion_user'=>author,'publication_key'=>'ordering'})
    ids=-> {screen.instance_variable_get(:@matches).drop(1).map{|match|match.fetch('match_id')}}
    expected=role==:observer ? %w[other other-return own own-return own-second own-done other-done] :
      %w[own own-return own-second other other-return own-done other-done]
    after=role==:observer ? %w[other other-return own-return own-second own-done own other-done] :
      %w[own-return own-second other other-return own-done own other-done]
    driver=TournamentNativeDriver.new
    driver.step('Tournament matches') do |form|
      assert_equal(expected,ids.call,"#{role}, teams=#{teams}: wrong initial priorities")
      assert_equal(8,form.fields.first.options.size,'The full list is not visible')
      assert_equal(0,form.fields.first.index,'Summary is not the first selected row')
      assert_equal('Tournament phase',form.fields[1].header,'Redundant match filter remains')
      form.fields.first.index=ids.call.index('own')+1
      SpeechOutput.reset
      completed<<receipt.call('own')
      revision+=1
    end
    driver.step('Tournament matches',[27]) do |form|
      assert_equal(after,ids.call,"#{role}, teams=#{teams}: result did not reorder the list")
      assert_equal('own',screen.instance_variable_get(:@matches)[form.fields.first.index]['match_id'],'Refresh selected a different match')
      assert_equal([],SpeechOutput.calls,'Priority reorder announced the list')
      assert_equal(before,Marshal.dump(candidate),'Presentation changed the match plan')
    end
    begin
      screen.run
      driver.finish
    ensure
      program.class.singleton_class.remove_method(:tournament_view_revision)
      program.finalize
      program.class.app_runtime.close
    end
  end
end
puts 'PASS full match ordering: own unfinished, other unfinished, completed; participants, playing organisers, spectators, teams, return matches and silent stable selection'
