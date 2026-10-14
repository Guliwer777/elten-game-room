if ARGV.first
  previous=ENV['ELTEN_TEST_NATIVE_CONTROLS']
  begin
    ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
    require_relative '../support/binary_rules_load'
  ensure
    ENV['ELTEN_TEST_NATIVE_CONTROLS']=previous
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../support/readiness_plan_table'
require_relative '../../lib/tournaments/server_schedule_overview'
require_relative '../../lib/tournaments/server_readiness_service'
include GameRoomTest::Assertions
T=GameRoomTournaments
fixture=TournamentIndividualUI.fixture
actor,now='Alice',100
table=ReadinessPlanTableSupport::Table.new(user:-> {actor},clock:-> {now})
candidate={'publication_ref'=>{'author'=>'alice','publication_key'=>'fixture'},'schedule_id'=>'a'*64,
  'publication_digest'=>'b'*64,'roster_generation'=>'c'*64,'state'=>'observed_candidate','finality'=>'unknown',
  'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false,'roster'=>%w[alice bob],
  'matches'=>[{'match_id'=>'d'*64,'leg'=>1,'number'=>1,'players'=>%w[alice bob]}]}
journal=T::OperationJournal.new(directory:File.join(fixture[:program].data_path,'shared-native-ready'),owner:'alice',backend_identity:'native-ready')
service=T::ServerReadinessService.new(table:table,journal:journal,user:-> {actor},source:->{{'candidate'=>candidate,'tournament_id'=>7}},clock:-> {now})
workspace=Object.new
workspace.define_singleton_method(:actor){actor}
workspace.define_singleton_method(:shared_schedule){|**|{'candidate'=>candidate,'storage'=>'confirmed'}}
workspace.define_singleton_method(:shared_readiness) do |available:,intent_id:,context:,lease:,**|
  raise 'Stale native view' unless context.current?(lease)
  available.nil? ? service.snapshot : service.set_available(available:available,intent_id:intent_id)
rescue IOError
  nil
end
owner=T::LocalTestDialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){raise message})
GameRoomLocalization.boot(settings:{'interface_language'=>'pl','known_languages'=>['pl']})
l=->(text){GameRoomContent.utf8(GameRoomLocalization.translate(text))}
header=l.call('Matches, groups and standings')
driver=TournamentNativeDriver.new
driver.step(header,[13]) do |form|
  assert_equal(0,table.insert_count,'Opening the tournament enabled readiness')
  assert(form.fields.find{|field|field.respond_to?(:header) && field.header==l.call('Shared player readiness')}.text.include?('alice: '+l.call('Availability disabled')), 'Missing disabled readiness state')
  form.index=form.fields.index(form.fields.find{|field|field.is_a?(Button) && field.label==l.call('I am ready to play')})
  form.focus
end
driver.step(header,[]) do |form|
  assert_equal(2,table.insert_count)
  details=form.fields.find{|field|field.respond_to?(:header) && field.header==l.call('Shared player readiness')}
  assert(details.text.include?('alice: '+l.call('Availability enabled')), 'Missing ready state')
  form.index=form.fields.index(form.fields.find{|field|field.is_a?(Button) && field.label==l.call('Disable my availability for automatic matches')})
  form.focus
end
driver.step(header,[13]){}
driver.step(header,[]) do |form|
  assert_equal(4,table.insert_count)
  assert(form.fields.find{|field|field.respond_to?(:header) && field.header==l.call('Shared player readiness')}.text.include?('alice: '+l.call('Availability disabled')), 'Missing disabled readiness state')
  table.on_select=-> {raise IOError,'Readiness server unavailable'}
  form.index=form.fields.index(form.fields.find{|field|field.is_a?(Button) && field.label==l.call('Refresh')})
  form.focus
end
driver.step(header,[13]){}
driver.step(header,[27]) do |form|
  assert_equal('',form.fields.find{|field|field.respond_to?(:header) && field.header==l.call('Shared player readiness')}.text,'Failed refresh retained an old readiness list')
end
begin
  T::ServerScheduleOverview.new(program:fixture[:program],workspace:workspace,owner:owner,
    publication:{'title'=>'Shared readiness','__insertion_user'=>'alice','publication_key'=>'fixture'}).run
  driver.finish
  assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native shared readiness: no opt-in on entry, explicit ready/disable, server observation display, failed-refresh clearing and clean resources; no invitations'
