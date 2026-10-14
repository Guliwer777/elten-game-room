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
require File.join(EltenTestHost.root,'src/ui/controls/static')
Object.const_set(:Static,EltenAPI::Controls.const_get(:Static)) unless Object.const_defined?(:Static)
require_relative '../../lib/tournaments/hub'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
fixture = I.fixture
driver = TournamentNativeDriver.new
driver.step(nil, [13]) do |form|
  form.index = form.fields.index(F.button(form, L.call('Create tournament')))
end
driver.step(L.call('Game'), [13]) do |form|
  assert_equal(L.call('Game'), form.fields.first.header)
  assert_equal(1,form.fields.count{|field|field.is_a?(ListBox)})
  assert(form.fields.none?{|field|field.is_a?(EditBox)},'Tournament fields leaked into game selection')
  form.fields.first.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe')
end
driver.step(nil,[27]) do |form|
  assert_equal([L.call('Next'),L.call('Cancel')],form.fields.grep(Button).map(&:label))
end
driver.step(L.call('Game'),[13]) do |form|
  assert(form.fields.none?{|field|field.is_a?(EditBox)},'Cancelled game options opened tournament rules')
end
driver.step(nil,[13]) do |form|
  assert(form.fields.none?{|field|field.respond_to?(:header) && field.header==L.call('Tournament name')},'Tournament fields leaked into game options')
  assert_equal([L.call('Next'),L.call('Cancel')],form.fields.grep(Button).map(&:label))
  form.index=form.fields.index(form.accept_button)
end
driver.step(L.call('Tournament name'), [27]) do |form|
  assert(form.fields.none?{|field|field.respond_to?(:header) && field.header==L.call('Game')},'Game list remains on tournament form')
  assert(form.fields.none?{|field|field.respond_to?(:header) && field.header==L.call('Tournament rules')}, 'Rules field remains')
  ['Tournament date','Last tournament day','Daily play starts','Daily play ends','Registration opens','Registration closes'].each do |label|
    assert_equal(1,form.fields.count{|field|field.respond_to?(:header) && field.header.to_s.start_with?(L.call(label)+': ')})
  end
  assert(!F.field(form,L.call('Tournament format')).options.include?(L.call('To be decided')),'Unspecified format remains')
  date=form.fields.find{|field|field.respond_to?(:header) && field.header.to_s.start_with?(L.call('Tournament date')+': ')}
  original_focus=date.method(:focus)
  spoken_headers=[]
  date.define_singleton_method(:focus){|*args|spoken_headers<<args[2];original_focus.call(*args)}
  date.trigger(:key_right)
  assert_equal(L.call('Month'),spoken_headers.last,'Right arrow repeated the complete tournament date header')
  assert(date.header.end_with?(L.call('Month')),'Right arrow did not select month')
  assert(form.fields.none? { |field| field.is_a?(Button) && field.label == L.call('Participants and playing windows') }, 'Nested old dialog remains')
end
driver.step(nil, [27])
T::Hub.new(**I.args(fixture).reject { |key, _| key == :clock }).run
driver.finish
assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native Polish root shortcut and inline setup fields in one tournament form'
