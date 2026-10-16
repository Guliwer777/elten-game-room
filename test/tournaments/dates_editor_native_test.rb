require_relative '../support/tournament_individual_ui'
require_relative '../support/tournament_window_fields'
require File.join(EltenTestHost.root,'src/ui/controls/static')
Object.const_set(:Static,EltenAPI::Controls.const_get(:Static)) unless Object.const_defined?(:Static)
require_relative '../../lib/tournaments/tournament_dates_editor'
include GameRoomTest::Assertions
T=GameRoomTournaments
%w[en pl cs es ru].each do |language|
  fixture=TournamentIndividualUI.fixture
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  l=->(s){GameRoomContent.utf8(GameRoomLocalization.translate(s))}
  alerts=[]
  values=T::TournamentDatesEditor.values(nil)
  editor=T::TournamentDatesEditor.new(program:fixture[:program],values:values,alert:->(s){alerts<<s},clock:-> {Time.utc(2026,10,14,12).to_i})
  driver=TournamentNativeDriver.new
  driver.step(l.call('Dates and playing hours'),[13]) do |form|
    editor.instance_variable_get(:@opening).index=2
    editor.send(:update_visibility)
    form.index=form.fields.index(form.accept_button)
  end
  result=editor.run
  driver.finish
  assert_equal({'opens'=>0,'closes'=>0,'starts'=>0,'deadline'=>0,'windows'=>[]},result)
  assert_equal(values,T::TournamentDatesEditor.values(nil),'Editor changed input values')
  editor=T::TournamentDatesEditor.new(program:fixture[:program],values:values,alert:->(s){alerts<<s},clock:-> {Time.utc(2026,10,14,12).to_i})
  driver=TournamentNativeDriver.new
  driver.step(l.call('Dates and playing hours'),[27]) do |form|
    editor.instance_variable_get(:@limited).checked=true
    editor.send(:save_dates)
    assert_equal(l.call('Add at least one playing window or turn off the playing-hours limit.'),alerts.last)
    assert(!editor.instance_variable_get(:@finished),'Invalid hours closed the form')
  end
  assert_equal(nil,editor.run)
  driver.finish
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native dates in five languages: independent manual controls, empty-window validation, cancel and clean resources'
