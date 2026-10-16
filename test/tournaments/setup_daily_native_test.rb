if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_individual_ui'
require_relative '../support/tournament_window_fields'
require File.join(EltenTestHost.root,'src/ui/controls/static')
Object.const_set(:Static,EltenAPI::Controls.const_get(:Static)) unless Object.const_defined?(:Static)
require_relative '../../lib/tournaments/tournament_setup_editor'
include GameRoomTest::Assertions
I=TournamentIndividualUI
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
fixture=I.fixture
daily=(16..18).map{|day|T::LocalRegistrationTime.utc_window(Time.local(2026,10,day,19).to_i,Time.local(2026,10,day,21).to_i)}
continuous=T::LocalRegistrationTime.utc_window(Time.local(2026,10,16,19).to_i,Time.local(2026,10,18,21).to_i)
[daily,[continuous]].each do |windows|
  draft={'name'=>'Weekend tournament','game_id'=>'tic_tac_toe','game_options'=>{},
    'format'=>'round_robin','players_per_match'=>2,'pairing'=>'all_combinations',
    'rematch'=>false,'windows'=>windows}
  publication=T::Publication.from_draft(draft:draft,registry:GameRoomGames::CATALOG,publication_key:'native-weekend',
    rules:'Test rules',registration_opens_at:120,registration_closes_at:240,timezone:'UTC').to_row
  saved=[]
  driver=TournamentNativeDriver.new
  driver.step('Tournament name',[13]) do |form|
    assert(!form.fields.any?{|field|field.respond_to?(:header) && field.header=='Tournament duration'},'Compact setup still forces duration')
    form.index=form.fields.index(I::F.button(form,'Dates and playing hours'))
  end
  driver.step('Dates and playing hours',[13]) do |form|
    list=I::F.field(form,'Playing windows')
    assert_equal(windows.size,list.options.size)
    assert(list.options.first.include?('2026-10-16 19:00'),'Local start changed on reopening')
    assert(list.options.last.include?('2026-10-18 21:00'),'Local end changed on reopening')
    form.index=form.fields.index(form.accept_button)
  end
  driver.step('Tournament name',[13]){|form|form.index=form.fields.index(form.accept_button)}
  T::TournamentSetupEditor.new(program:fixture[:program],registry:GameRoomGames::CATALOG,
    configure:->(*){raise 'Edit requested game configuration'},publication:publication,
    alert:->(message){raise message},publish:->(**values){saved<<values;{'status'=>'confirmed'}}).wait
  driver.finish
  assert_equal(windows,saved.first[:draft]['windows'],'An edit replaced the existing windows')
  assert_equal(T::LocalRegistrationTime.convert_utc(windows.first['date'],windows.first['start']),saved.first[:draft]['starts_at'])
  assert_equal(240,saved.first[:registration_closes_at])
end
# Cancelling the optional dates dialog leaves a new manual tournament manual.
saved=[]
driver=TournamentNativeDriver.new
driver.step('Game',[13]){|form|form.fields.first.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe')}
driver.step('Tournament name',[13]) do |form|
  I::F.field(form,'Tournament name').set_text('Manual tournament')
  form.index=form.fields.index(I::F.button(form,'Dates and playing hours'))
end
driver.step('Dates and playing hours',[27])
driver.step('Tournament name',[13]){|form|form.index=form.fields.index(form.accept_button)}
T::TournamentSetupEditor.new(program:fixture[:program],registry:GameRoomGames::CATALOG,configure:->(_game,options){options},
  clock:-> {Time.local(2026,10,13,15).to_i},alert:->(message){raise message},
  publish:->(**values){saved<<values;{'status'=>'confirmed'}}).wait
driver.finish
assert_equal([],saved.first[:draft]['windows'])
assert_equal(0,saved.first[:draft]['starts_at'])
assert_equal(0,saved.first[:registration_closes_at])
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native optional dates: daily/overnight UTC windows preserved on edit, local display and cancelled dates retain manual start'
