if ARGV.first
  previous = ENV['ELTEN_TEST_NATIVE_CONTROLS']
  begin
    ENV['ELTEN_TEST_NATIVE_CONTROLS'] = '1'
    require_relative '../support/binary_rules_load'
  ensure
    ENV['ELTEN_TEST_NATIVE_CONTROLS'] = previous
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../support/tournament_context_native'
require_relative '../../lib/tournaments/server_schedule_overview'
require_relative '../../lib/tournaments/operations_screen'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
fixture = I.fixture
completed=false
fixture[:program].define_singleton_method(:open_ordinary_tournament_match){|*|raise 'Unexpected table creation'}
fixture[:program].define_singleton_method(:ordinary_tournament_overview) do |publication,workspace:,context:,lease:,**|
  schedule=workspace.shared_schedule(publication_ref:publication.slice('__insertion_user','publication_key'),context:context,lease:lease)
  next nil unless schedule
  first={'match_id'=>'a'*64,'leg'=>1,'summary'=>{'draw'=>false,'winners'=>['guliwer'],'participants'=>%w[Żółw guliwer],'scores'=>{'Żółw'=>4,'guliwer'=>7}}}
  schedule.merge('results'=>{'results'=>completed ? [first,first.merge('match_id'=>'b'*64,'leg'=>2)] : [first], 'standings'=>[], 'completed'=>completed})
end
label = GameRoomTournaments::OperationsScreen.allocate.send(:label,
  {'kind' => 'plan_document', 'status' => 'attempted', 'values' => {'tournament_id' => 7}})
assert_equal((L.call('Server match plan: tournament %{id}') % {id: 7}) + '; ' + L.call('attempted; not confirmed'), label)
workspace = Object.new
workspace.define_singleton_method(:actor) { 'guliwer' }
calls = 0
workspace.define_singleton_method(:shared_schedule) do |publication_ref:, context:, lease:|
  raise 'Stale context' unless context.current?(lease)
  calls += 1
  next nil if calls > 2
  {'storage' => 'confirmed', 'candidate' => {'schedule_id'=>'c'*64,'format'=>'groups_knockout','groups' => [{'id' => 'group-1', 'units' => %w[Żółw guliwer], 'matches' => ['a'*64]}],
    'matches' => [{'match_id' => 'a'*64, 'number'=>1, 'leg' => 1, 'players' => %w[Żółw guliwer]},
      {'match_id' => 'b'*64, 'number'=>2, 'leg' => 2, 'players' => %w[Żółw guliwer]}]}}
end
owner = GameRoomTournaments::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(message) { raise message })
driver = TournamentNativeDriver.new
header=->(done){L.call('Matches — %{phase}; completed: %{done}/%{total}')%{phase:L.call('Group stage'),done:done,total:2}}
context=->(list){ menu=Object.new; labels=[]; menu.define_singleton_method(:option){|label,*|labels<<label}; list.context(menu,false); labels }
combined_context=->(form,expected){
  fixture[:program].define_singleton_method(:switch_to_invited_table){}
  items=TournamentNativeContext.items(form)
  assert_equal([*expected.map(&L),L.call('Accept invitation')],items.map(&:first),'Host menu places invitation before match actions or duplicates it')
  assert_equal('j',items.last.last)
  fixture[:program].singleton_class.remove_method(:switch_to_invited_table)
}
driver.step(L.call('Matches'), [13]) do |form|
  list=form.fields.first
  assert_equal(3,list.options.size)
  assert_equal(header.call(1),list.options.first)
  assert_equal(0,list.index,'The summary was not selected')
  assert(context.call(list).empty?,'Summary exposes fixture actions')
  combined_context.call(form,[])
  list.index=2
  list.trigger(:move)
  assert(list.options.last.include?('Żółw — guliwer') && list.options.last.include?(L.call('Winner: %{players}')%{players:'guliwer'}),'Names or winner missing')
  assert_equal('guliwer — Żółw; '+L.call('Return match')+'; '+L.call('To be played'),list.options[1],'Unplayed return match missing below summary')
  assert(!list.options.join.include?('a'*64),'Digest leaked into match labels')
  assert(!context.call(list).include?(L.call('Play')),'Completed match exposes Play')
  combined_context.call(form,['Match result'])
  list.index=1
  list.trigger(:move)
  assert(context.call(list).include?(L.call('Play')),'Own unplayed match hides Play')
  combined_context.call(form,['Play'])
  completed=true
  form.index=form.fields.index(F.button(form,L.call('Refresh')))
end
driver.step(L.call('Matches'), []){}
driver.step(L.call('Matches'), [13]) do |form|
  assert_equal(header.call(2),form.fields.first.options.first)
  assert_equal(2,form.fields.first.index,'Completion moved the selection away from the return match')
  details=F.field(form,L.call('Information'))
  assert(details.text.include?(L.call('Completed — all required matches have been resolved')),'Finished tournament still invites the player to play')
  assert(!context.call(form.fields.first).include?(L.call('Play')),'Finished tournament exposes Play')
  form.index=form.fields.index(F.button(form,L.call('Refresh')))
end

driver.step(L.call('Matches'), [27]) do |form|
  assert(form.fields.first.options.empty?,'Failed refresh retained actionable matches')
  assert(context.call(form.fields.first).empty?,'Failed refresh retained actions')
  form.index=0
  combined_context.call(form,[])
end
begin
  GameRoomTournaments::ServerScheduleOverview.new(program: fixture[:program], workspace: workspace, owner: owner,
    publication: {'title' => 'Podgląd wspólnego planu', '__insertion_user' => F::OWNER, 'publication_key' => 'test-plan'}).run
  driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native Polish shared plan: names, groups, return leg, read-only controls, failed-refresh clearing and closed resources'

%w[en pl cs es ru].each do |language|
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  summary={'draw'=>false,'winners'=>['red'],'participants'=>%w[blue red],'scores'=>{'red'=>12,'blue'=>4}}
  label=GameRoomTournaments::ServerScheduleOverview.allocate.send(:result_label,summary,{'red'=>'Alice + Bob','blue'=>'Carol + Dave'})
  assert(label.include?('Alice + Bob: 12') && label.include?('Carol + Dave: 4'),'Team small scores missing names')
  assert(!label.include?('red') && !label.include?('blue'),'Internal team ID leaked into result')
end
puts 'PASS EN/PL/CS/ES/RU shared team result presentation'
