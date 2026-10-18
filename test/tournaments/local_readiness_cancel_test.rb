# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
H=TournamentLocalHubTest
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
GameRoomTest::TemporaryDirectory.create('d2b-cancel-') do |directory|
  program=TournamentMatchEntryTest.prepare(directory)
  hub=T::LocalTestHub.new(**H.args(program:program))
  driver=TournamentNativeDriver.new
  parent=nil
  complete=lambda do
    screen=hub.instance_variable_get(:@match_entry)
    work=screen.instance_variable_get(:@readiness_work)
    wait_background_work(work)
    parent.update
  end
  driver.open_test_participant
  driver.step('Choose a test participant',[13]) do |form|
    H.field(form,'Test participant name').set_text('Alicja')
    form.index=form.fields.index(H.button(form,'Use test participant'))
  end
  driver.step('Local tournament tests',[13]) { |form|form.index=form.fields.index(H.button(form,'My matches — readiness and coordination')) }
  driver.step('My tournaments') do |form|
    parent=form
    H.button(form,'Check status').press;complete.call
    H.button(form,'Prepare local test plan').press;complete.call
  end
  driver.step('Local test plan',[13]) do |form|
    # Enter na treści nie jest świadomym zatwierdzeniem.
    form.index=0
  end
  driver.step('Local test plan',[27]) do |_form|
    screen=hub.instance_variable_get(:@match_entry)
    assert(screen.instance_variable_get(:@busy),'Modal bez busy')
    H.button(parent,'Prepare local test plan').press
    H.button(parent,'Ready').press
    H.button(parent,'Back').press
  end
  driver.step('My tournaments',[27]) do |form|
    assert(H.field(form,'Readiness and coordination').text.include?('No local test plan has been accepted'),'Anulowanie pozostawiło nieprawdziwy status workera')
    assert(Dir.glob('tournament-readiness-k03-*/backend/sandbox-k03.json',base:directory).empty?,'Cancel/Enter zatwierdził plan')
  end
  driver.step('Local tournament tests',[27])
  hub.run
  driver.finish
end
puts 'PASS Enter tekstu/Cancel nie zapisują, pełny modal pod busy i zgodny stan po powrocie'
