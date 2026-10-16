if ARGV.first
  previous=ENV['ELTEN_TEST_NATIVE_CONTROLS']
  begin
    ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
    require_relative '../support/binary_rules_load'
  ensure
    ENV['ELTEN_TEST_NATIVE_CONTROLS']=previous
  end
end
require_relative '../support/tournament_native'
require_relative '../support/tournament_public_ui'
require_relative '../support/localization'
require_relative '../../lib/tournaments/public_screen'
GameRoomTestLocalization.use_language('en')
u=TournamentPublicUI
now=Time.utc(2026,10,13,9,59,59).to_i
boundary=now+1
make=->(id,start,ending,opens,closes){u.publication(id).merge('timezone'=>'UTC','registration_opens_at'=>opens,'registration_closes_at'=>closes,
  'schedule_json'=>JSON.generate({'windows'=>[{'date'=>'2026-10-13','start'=>start,'end_date'=>'2026-10-13','end'=>ending}]}))}
waiting=make.call(11,'10:00','14:00',now-7200,now-3600)
soon=make.call(22,'12:00','14:00',boundary,now+3600)
finishing=make.call(33,'09:00','10:00',now-7200,now-3600)
early=make.call(44,'09:00','14:00',now-7200,now-3600).merge('sporting_completed'=>true,'sporting_completed_at'=>now-120)
snapshot=u.snapshot([waiting,soon,finishing,early],[u.registration(77,tournament_id:11,time:now-5000)])
snapshot=JSON.parse(JSON.generate(snapshot))
snapshot['announcements'].find{|row|row['__id']==44}.merge!('sporting_completed'=>true,'sporting_completed_at'=>now-120)
reads=0;joins=[];parent=nil
driver=TournamentNativeDriver.new
driver.step('Tournaments') do |form|
  parent=form
  assert_equal([11,22,33],form.fields[0].instance_variable_get(:@item_keys))
  assert_equal(0,form.index)
  timer=form.instance_variable_get(:@timers).first
  assert(timer,'Missing deadline event')
  now=boundary
  timer.instance_variable_set(:@monotonic_starttime,Process.clock_gettime(Process::CLOCK_MONOTONIC)-2)
end
driver.press('Tournaments',9) do |form|
  assert_equal([11,22],form.fields[0].instance_variable_get(:@item_keys))
  assert_equal(1,reads,'Deadline event polled the backend')
  assert_equal(1,form.instance_variable_get(:@timers).size,'Deadline event accumulated timers')
end
driver.press('Tournaments',39){|form|assert_equal(1,form.index)}
driver.press('Tournaments',39) do |form|
  assert_equal([11],form.fields[0].instance_variable_get(:@item_keys))
  assert(form.fields[0].options.first.include?('You are registered'),'Own membership was not labelled')
end
driver.step('Tournaments',[13]) do |form|
  assert_equal([33,44],form.fields[0].instance_variable_get(:@item_keys))
  form.fields[0].index=1
  form.index=0
end
driver.step(/\APróba 44 — Łódź — /,[27]){|form|assert(form.fields.first.header.include?('Próba 44'),'Ended Enter lost the previously selected completed tournament')}
driver.step('Tournaments',[27]){|form|assert_equal(0,form.index);assert_equal(1,form.fields[0].index);assert_equal([],joins)}
args=u.arguments(snapshot,load:->{reads+=1;snapshot},join:->(id){joins<<id;u.record('confirmed')}).reject{|key,_|[:publication,:snapshot].include?(key)}
GameRoomTournaments::PublicScreen.new(**args,clock:->{now}).run
driver.finish
assert_equal([],parent.instance_variable_get(:@timers),'Closed list retained its deadline callback')
puts 'PASS native directory: one list, own/completed filters, deadlines without polling, stable selected ID and timer cleanup'
