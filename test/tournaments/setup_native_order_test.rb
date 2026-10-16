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
  assert_equal(1,form.fields.grep(Button).count{|field|field.label==L.call('Dates and playing hours')})
  assert(form.fields.none?{|field|field.respond_to?(:header) && field.header.to_s.start_with?(L.call('Tournament date')+': ')},'Optional dates clutter the main form')
  assert(!F.field(form,L.call('Tournament format')).options.include?(L.call('To be decided')),'Unspecified format remains')
  assert(form.fields.none? { |field| field.is_a?(Button) && field.label == L.call('Participants and playing windows') }, 'Nested old dialog remains')
end
args=I.args(fixture)
configure=->(game,options){GameRoomOptionEditor.new(program:fixture[:program],defaults:->(model,_){model.default_options},remember:->(*){},alert:args[:alert]).
  edit(game,initial_options:options,submit_label:L.call('Next'),require_confirmation:true)}
T::TournamentSetupEditor.new(program:fixture[:program],registry:args[:registry],configure:configure,
  publish:->(**){raise 'Cancelled setup must not publish'},alert:args[:alert]).wait
driver.finish
assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native Polish game/options/setup sequence, cancellation and optional dates'
