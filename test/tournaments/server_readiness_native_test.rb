if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/server_schedule_overview'
include GameRoomTest::Assertions
T=GameRoomTournaments
fixture=TournamentIndividualUI.fixture
candidate={'format'=>'round_robin','publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'schedule_id'=>'a'*64,
  'roster'=>%w[alice bob],'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}]}
workspace=Object.new
workspace.define_singleton_method(:actor){'Alice'}
reads=0
workspace.define_singleton_method(:shared_schedule) do |**|
  reads+=1
  reads==1 ? {'candidate'=>candidate,'storage'=>'confirmed'} : nil
end
workspace.define_singleton_method(:shared_readiness){|**|raise 'The match list must not read or write global readiness'}
fixture[:program].define_singleton_method(:ordinary_tournament_overview) do |_,workspace:,**|
  schedule=workspace.shared_schedule
  schedule && schedule.merge('results'=>{'results'=>[],'standings'=>[]})
end
owner=T::LocalTestDialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){raise message})
GameRoomLocalization.boot(settings:{'interface_language'=>'pl','known_languages'=>['pl']})
l=->(text){GameRoomContent.utf8(GameRoomLocalization.translate(text))}
driver=TournamentNativeDriver.new
driver.step(l.call('Matches'),[13]) do |form|
  assert_equal(1,reads)
  labels=form.fields.map{|field|field.is_a?(Button) ? field.label : field.header if field.respond_to?(:header) || field.is_a?(Button)}
  ['Shared player readiness','I am ready to play','Disable my availability for automatic matches'].each do |label|
    assert(!labels.include?(l.call(label)),"Obsolete readiness control: #{label}")
  end
  form.index=form.fields.index(form.fields.find{|field|field.is_a?(Button) && field.label==l.call('Refresh')})
end
driver.step(l.call('Matches'),[27]) do |form|
  assert_equal(2,reads)
  list=form.fields.first
  assert_equal([],list.options,'Failed refresh retained an old match plan')
end
begin
  T::ServerScheduleOverview.new(program:fixture[:program],workspace:workspace,owner:owner,
    publication:{'title'=>'No global readiness','__insertion_user'=>'alice','publication_key'=>'fixture'}).run
  driver.finish
  assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native match list: no separate readiness gate or requests, failed-refresh clearing and clean resources'
