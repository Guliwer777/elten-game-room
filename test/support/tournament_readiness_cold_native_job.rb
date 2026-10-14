# encoding: UTF-8
require_relative 'tournament_native'
require_relative 'tournament_local_hub'
require_relative 'tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
require 'json'
extend GameRoomTest::Assertions
H=TournamentLocalHubTest
T=GameRoomTournaments
mode,directory=ARGV
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
program=mode=='a' ? TournamentMatchEntryTest.prepare(directory) : TournamentEntryContextTest::Program.new(directory)
hub=T::LocalTestHub.new(**H.args(program:program))
driver=TournamentNativeDriver.new
parent=nil
complete=lambda do
  screen=hub.instance_variable_get(:@match_entry)
  work=screen.instance_variable_get(:@readiness_work)
  wait_background_work(work) if work && work.busy?
  parent.update
end
no_store=TracePoint.new(:call) do |event|
  raise 'Zimny UI ponownie wysłał operację' if event.defined_class==T::LocalReadinessBackend && [:store,:accept].include?(event.method_id)
end
no_store.enable unless mode=='a'
driver.step('Choose a test participant',[13]) do |form|
  H.field(form,'Test participant name').set_text(mode=='bob' ? 'Bob' : 'Alicja')
  form.index=form.fields.index(H.button(form,'Use test participant'))
end
driver.step('Local tournament tests',[13]) { |form|form.index=form.fields.index(H.button(form,'My matches — readiness and coordination')) }
driver.step('My tournaments') do |form|
  parent=form
  H.button(form,'Check status').press
  complete.call
  if mode=='a'
    H.button(form,'Prepare local test plan').press
    complete.call
  elsif mode=='history'
    assert_equal([],H.field(form,'My matches').options)
    assert(!H.field(form,'Accepted local matches — historical readback').options.empty?,'Historia zniknęła po utracie bieżącego źródła')
    H.button(form,'Read selected local record').press
    complete.call
  end
end
if mode=='a'
  driver.step('Local test plan',[13]) { |form|form.index=form.fields.index(H.button(form,'Accept local test plan')) }
end
driver.step('My tournaments') do |form|
  complete.call
  if mode=='a'
    H.button(form,'Ready').press;complete.call
    original=File.method(:rename)
    once=true
    File.define_singleton_method(:rename) do |from,to|
      result=original.call(from,to)
      if once && to.end_with?('sandbox-k03.json')
        once=false
        raise IOError,'Brak odpowiedzi po rename z rzeczywistego UI'
      end
      result
    end
    begin
      H.button(form,'Withdraw readiness').press;complete.call
    ensure
      File.define_singleton_method(:rename,original)
    end
    assert(H.field(form,'Readiness and coordination').text.include?('Operation result: unknown'),'Brak niepewności UI')
    screen=hub.instance_variable_get(:@match_entry)
    records=screen.instance_variable_get(:@readiness_state)[:records]
    id=records.find { |record|record['operation']['request']['availability']=='withdrawn' }['operation']['operation_id']
    File.write(File.join(directory,'native-operation.json'),JSON.generate({uuid:id,pid:Process.pid}),encoding:'UTF-8')
  elsif mode=='bob'
    assert(H.field(form,'Readiness and coordination').text.include?('Own readiness: unknown'),'Wyciek stanu innego aktora')
    assert_equal([],H.field(form,'Readiness operations').options)
  else
    data=JSON.parse(File.read(File.join(directory,'native-operation.json'),encoding:'UTF-8'))
    assert(data['pid']!=Process.pid,'To nie jest zimny proces')
    list=H.field(form,'Readiness operations')
    assert_equal(2,list.options.size)
    index=list.options.index { |text|text.include?(data['uuid']) }
    assert(!index.nil?,'Nie odnaleziono UUID po zamknięciu procesu')
    list.index=index
    H.button(form,'Check uncertain operation').press;complete.call
    status=H.field(form,'Readiness and coordination').text
    assert(status.include?("Operation result: confirmed; original UUID: #{data['uuid']}"),'Brak exact cold readback UI')
    assert(status.include?('Own readiness: withdrawn'),'Zgubiono withdrawn po restarcie')
  end
end
driver.step('My tournaments',[27])
driver.step('Local tournament tests',[27])
begin
  hub.run
  driver.finish
ensure
  no_store.disable
end
assert_equal(0,program.managed_resources.size)
assert_equal(0,program.class.app_runtime.managed_resources.size)
puts "PASS zimny native #{mode}, PID=#{Process.pid}; własne kontrolki/UUID bez store/reaccept"
