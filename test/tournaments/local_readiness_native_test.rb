# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
extend GameRoomTest::Assertions
def self.assert(value, message = 'Asercja lokalnego pionu UI')
  super(value, message)
end
H=TournamentLocalHubTest
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
Dir.mktmpdir('d2b-ui-',ENV.fetch('TMPDIR')) do |directory|
  program=TournamentMatchEntryTest.prepare(directory)
  hub=T::LocalTestHub.new(**H.args(program:program))
  driver=TournamentNativeDriver.new
  parent=nil
  complete=lambda do
    screen=hub.instance_variable_get(:@match_entry)
    work=screen.instance_variable_get(:@readiness_work)
    wait_background_work(work) if work && work.busy?
    parent.update
  end
  driver.open_test_participant
  driver.step('Choose a test participant',[13]) do |form|
    H.field(form,'Test participant name').set_text('Alicja')
    form.index=form.fields.index(H.button(form,'Use test participant'))
  end
  driver.step('Local tournament tests',[13]) { |form| form.index=form.fields.index(H.button(form,'My matches — readiness and coordination')) }
  driver.step('My tournaments') do |form|
    parent=form
    assert(form.fields.grep(Button).any? { |button| button.label=='Prepare local test plan' },'Brak osiągalnej akcji jawnego planu')
    H.button(form,'Check status').press
    complete.call
    assert(H.field(form,'Readiness and coordination').text.include?('No local test plan has been accepted'), 'Brak stanu bez lokalnego planu')
    H.button(form,'Prepare local test plan').press
    complete.call
  end
  driver.step('Local test plan',[13]) do |form|
    content=H.field(form,'Local test plan').text
    %w[alicja bob celina dawid].each { |name| assert(content.include?(name),'Podgląd zgubił pełny skład') }
    assert(content.include?('not a server seal'))
    form.index=form.fields.index(H.button(form,'Accept local test plan'))
  end
  driver.step('My tournaments') do |form|
    complete.call
    assert(H.field(form,'Readiness and coordination').text.include?('Own readiness: unknown'))
    screen=hub.instance_variable_get(:@match_entry)
    backend=screen.controller.instance_variable_get(:@readiness_connection).instance_variable_get(:@backend)
    original_store=backend.method(:store)
    entered,release=Queue.new,Queue.new
    backend.define_singleton_method(:store) do |**options|
      entered << true
      release.pop
      original_store.call(**options)
    end
    selected=H.field(form,'My matches').index
    H.button(form,'Ready').press
    Timeout.timeout(5) {entered.pop}
    H.field(form,'My matches').index=1
    H.button(form,'Ready').press
    H.button(form,'Withdraw readiness').press
    form.game_room_hotkey_action(1).call
    assert(screen.instance_variable_get(:@readiness_pending), 'Powtórne kliknięcie zdjęło busy')
    release << true
    complete.call
    backend.define_singleton_method(:store,original_store)
    assert_equal(selected,H.field(form,'My matches').index,'Worker zgubił wybrane spotkanie')
    assert(H.field(form,'Readiness and coordination').text.include?('Own readiness: ready'))
    H.button(form,'Withdraw readiness').press
    complete.call
    assert(H.field(form,'Readiness and coordination').text.include?('Own readiness: withdrawn'))
    operations=H.field(form,'Readiness operations')
    assert_equal(2,operations.options.size)
    H.button(form,'Check uncertain operation').press
    complete.call
    assert(H.field(form,'Readiness and coordination').text.include?('not an invitation'))
    H.button(form,'Propose playing now').press
    assert(H.field(form,'Readiness and coordination').text.include?('unavailable'))
  end
  driver.step('My tournaments',[27])
  driver.step('Local tournament tests',[27])
  hub.run
  driver.finish
  assert_equal(0,program.managed_resources.size)
  assert_equal(0,program.class.app_runtime.managed_resources.size)
end
puts 'PASS native Hub → pełny plan/accept → Ready/Withdraw → historia/readback, bez żywych wyjść'
