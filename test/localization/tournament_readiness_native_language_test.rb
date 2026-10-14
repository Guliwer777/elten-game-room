# encoding: UTF-8
require_relative '../support/tournament_local_test_language'
require_relative '../../tools/support/translation_catalog'
require_relative '../../tools/support/translation_extractor'
require 'digest'
require 'json'
require 'tmpdir'
L=TournamentLocalTestLanguage
language=ARGV.fetch(0)
L.check(%w[pl en fallback].include?(language),'Nieznany tryb języka')
host,before,fixture=L.boot_native(language=='pl' ? 'pl' : 'en')
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
T=GameRoomTournaments
root=File.expand_path('../..',__dir__)
translations=JSON.parse(File.read(File.join(ENV.fetch('D2B_OUT'),'translations.json'),encoding:'UTF-8'))
originals=GameRoomTranslationCatalog.message_map(GameRoomTranslationCatalog.read_po(File.join(ENV.fetch('D2B_OUT'),'before/locale/PL.po')))
expected=originals.merge(translations)
if language=='fallback'
  # Rzeczywisty brak nowych PL, bez zmiany słownika ani globalnego gettext.
  labels=->(message) { originals[message].to_s.empty? ? message : originals[message] }
  GameRoomLocalization.boot(directory:File.join(ENV.fetch('D2B_OUT'),'before/locale'),
    settings:{'interface_language'=>'pl','known_languages'=>['pl']})
else
  labels=->(message) {language=='pl' ? (expected[message].to_s.empty? ? message : expected[message]) : message}
end
# Wymagany strict lookup całych komunikatów, nie samo UTF-8/fallback.
raw=GetText::MO.open(File.join(root,'locale/PL.mo')).to_h.transform_keys(&:b).transform_values(&:b)
translations.each { |msgid,polish| L.equal(polish.b,raw.fetch(msgid.b),"MO: #{msgid}") }
Dir.mktmpdir('d2b-language-',ENV.fetch('TMPDIR')) do |directory|
  program=TournamentMatchEntryTest.prepare(directory)
  hub=T::LocalTestHub.new(program:program,registry:GameRoomGames::CATALOG,user:-> {'RealOwner'},
    alert:->(message) {raise message},confirm:->(*) {raise 'Nieoczekiwany modal'},clock:-> {201})
  driver=TournamentNativeDriver.new
  label=labels
  field=->(form,name) {L.field(form,label.call(name))}
  button=->(form,name) {L.button(form,label.call(name))}
  complete=lambda do |form|
    work=hub.instance_variable_get(:@match_entry).instance_variable_get(:@readiness_work)
    wait_background_work(work) if work && work.busy?
    form.update
  end
  driver.step(label.call('Choose a test participant'),[13]) do |form|
    field.call(form,'Test participant name').set_text('Alicja')
    form.index=form.fields.index(button.call(form,'Use test participant'))
  end
  driver.step(label.call('Local tournament tests'),[13]) { |form| form.index=form.fields.index(button.call(form,'My matches — readiness and coordination')) }
  driver.step(label.call('My tournaments')) do |form|
    L.read_form(form)
    button.call(form,'Check status').press
    complete.call(form)
    button.call(form,'Prepare local test plan').press
    complete.call(form)
  end
  driver.step(label.call('Local test plan'),[13]) do |form|
    L.read_form(form)
    warning=label.call('WARNING: local trial only, not a server seal. Acceptance saves an immutable full local plan. It does not assign game roles, teams, starting seats or scoring and cannot start a match.')
    L.check(field.call(form,'Local test plan').text.start_with?(warning+"\r\n"),'Pełne ostrzeżenie/CRLF')
    form.index=form.fields.index(button.call(form,'Accept local test plan'))
  end
  driver.step(label.call('My tournaments')) do |form|
    complete.call(form)
    L.read_form(form)
    button.call(form,'Ready').press;complete.call(form)
    state=label.call('Own readiness: %{state}; revision: %{revision}') % {state:label.call('ready'),revision:1}
    L.check(field.call(form,'Readiness and coordination').text.split("\r\n").include?(state),'Brak pełnego stanu ready')
    button.call(form,'Withdraw readiness').press;complete.call(form)
    state=label.call('Own readiness: %{state}; revision: %{revision}') % {state:label.call('withdrawn'),revision:2}
    L.check(field.call(form,'Readiness and coordination').text.split("\r\n").include?(state),'Brak pełnego stanu withdrawn')
    L.read_form(form)
    form.game_room_hotkey_action(1).call
  end
  driver.step(label.call('Keyboard shortcuts'),[27]) { |form| L.read_form(form) }
  driver.step(label.call('My tournaments'),[27])
  driver.step(label.call('Local tournament tests'),[27])
  hub.run
  driver.finish
end
L.equal(before,L.host_snapshot,'Zmieniono słownik hosta')
loaded=L::NativeSources.loaded
L.check(loaded.keys.any? { |path| path.end_with?('local_readiness_screen.rb') },'Nie załadowano nowego UI binarnie')
L.check(loaded.values.all? { |encoding| encoding==Encoding::ASCII_8BIT },'Loader wymusił UTF-8')
puts "PASS native binary #{language}: pełne kontrolki/PL/EN/fallback, F1, ready/withdrawn, ścisłe MO i CRLF, bez zmiany hosta"
