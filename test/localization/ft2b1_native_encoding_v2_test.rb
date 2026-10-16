# encoding: UTF-8
require_relative '../support/tournament_ft2b1_localization_loader'
mode, language = ARGV
raise 'Podaj source|binary i pl|en|missing-new-pl' unless %w[source binary].include?(mode) && %w[pl en missing-new-pl].include?(language)
loader = TournamentFT2B1LocalizationLoader
loader.prepare
Kernel.prepend(loader::Requires) if mode == 'binary'
require_relative '../support/tournament_native'
require_relative '../support/localization'
# Usunięcie atrap helpera przywraca rzeczywisty Dictionary hosta; bez zmian gettext.
Object.send(:remove_method, :_)
Object.send(:remove_method, :p_)
require EltenTestHost.file('src/eapi/dictionary.rb')
Object.include(EltenAPI)
Configuration.language = 'pl-PL'
EltenAPI::Structs::Lists.langs = {'en' => {'nativeName' => 'English'}}
host = Object.new
host.send(:loadmo, File.binread(EltenTestHost.file('locale/pl-PL/LC_MESSAGES/elten.mo')))
raise 'Nie działa polski host' unless host.send(:_, 'Cancel') == 'Anuluj'
raise 'Podmieniony gettext' unless host.method(:_).owner == EltenAPI::Dictionary
host_snapshot = -> { Marshal.dump([:Catalogs, :Docs, :Languages].map { |key| EltenAPI::Dictionary.const_get(key) }) }
host_before = host_snapshot.call
missing = language == 'missing-new-pl'
mo_path = missing ? File.join(ENV.fetch('FT2_SCRATCH'), 'shared/missing/PL.mo') : File.join(loader::ROOT, 'locale/PL.mo')
runtime = GameRoomTestLocalization.runtime(language == 'en' ? 'en' : 'pl', files: {'pl' => mo_path})
GameRoomLocalization.boot(runtime: runtime)
if missing
  catalog = GameRoomLocalization::Catalog.new(File.binread(mo_path))
  removed = JSON.parse(File.binread(File.join(ENV.fetch('FT2_SCRATCH'), 'shared/missing/removed.json')))
  raise 'Brak nowych kluczy nie jest rzeczywisty' unless removed.size == 33 && removed.all? { |id| catalog.translate(id).nil? }
  raise 'Usunięto też stare tłumaczenia' unless catalog.translate('Back') == 'Wstecz'
end
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja lokalizacji FT2B'); super(value, message); end
f = TournamentFT2B1
translate = ->(id) { GameRoomLocalization.translate(id) }
field = ->(form, id) { f.field(form, translate.call(id)) }
button = ->(form, id) { f.button(form, translate.call(id)) }
main = translate.call('Accepted fixed-team plans')
raise 'Błędna nowa etykieta' unless main == (language == 'pl' ? 'Zaakceptowane plany stałych ekip' : 'Accepted fixed-team plans')
snapshots, failures = [], []
verify_text = lambda do |actual, expected, gate|
  # EditBox przechowuje CRLF; nie zmieniamy kodowania ani tekstu hosta.
  expected = expected.gsub(/\r?\n/, "\r\n")
  failures << {gate: gate, actual: actual, expected: expected} unless actual.include?(expected)
end
read_form = lambda do |form|
  values = []
  original = form.index
  form.fields.each_with_index do |control, index|
    next unless control
    labels = []
    labels << control.header if control.respond_to?(:header)
    labels << control.label if control.is_a?(Button)
    labels.concat(control.options) if control.is_a?(ListBox)
    labels << control.text if control.is_a?(EditBox)
    labels.compact.each do |value|
      assert(value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?, "Błędny tekst kontrolki #{value.inspect}")
      values << value
    end
    speech, braille = SpeechOutput.calls.size, NVDA.calls.size
    form.index = index
    form.focus
    assert(SpeechOutput.calls.size > speech && NVDA.calls.size > braille, 'Brak rzeczywistego odczytu kontrolki')
    [SpeechOutput.calls.last.first, NVDA.calls.last.first].each { |s| assert(s.valid_encoding?, 'Niepoprawne bajty odczytu') }
  end
  snapshots << {header: form.fields.first.header, values: values}
  form.index = original
  form.focus
end
fixture = f.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
record = fixture[:record]
begin
  %w[Anna Bartek Beata].each do |actor|
    f.with_execution(fixture, actor) do |execution|
      f.select_execution(execution, record)
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  driver = TournamentNativeDriver.new
  hub = f::T::LocalTestHub.new(**f.args(fixture))
  complete = lambda do |form|
    2.times do
      screen = hub.instance_variable_get(:@fixed_team_entry)
      work = screen.instance_variable_get(:@readiness_work)
      wait_background_work(work, timeout: 30) if work && work.busy?
      form.update
    end
  end
  driver.open_test_participant
  driver.step(translate.call('Choose a test participant'), [13]) do |form|
    field.call(form, 'Test participant name').set_text('Ala')
    read_form.call(form)
    form.index = form.fields.index(button.call(form, 'Use test participant'))
  end
  driver.step(translate.call('Local tournament tests'), [13]) do |form|
    read_form.call(form)
    form.index = form.fields.index(button.call(form, 'Fixed teams — local execution'))
  end
  driver.step(main) do |form|
    read_form.call(form)
    button.call(form, 'Check status').press; complete.call(form)
    button.call(form, 'Ready').press; complete.call(form)
    assert_equal('ready', hub.instance_variable_get(:@fixed_team_entry).controller.view[:current]['state'])
    button.call(form, 'Prepare local target').press; complete.call(form)
    assert(field.call(form, 'Fixed-team execution status').text.include?(translate.call('Choose a technical deadline before preparing a local target.')), 'Brak jawnej odmowy bez terminu')
    read_form.call(form)
    form.game_room_hotkey_action(1).call
  end
  driver.step(translate.call('Keyboard shortcuts'), [27]) do |form|
    read_form.call(form)
    assert(form.fields.first.text.include?(translate.call('Ready is not consent or entry. Each test participant must consent and confirm entry separately.')), 'F1 zgubił granicę zgody')
  end
  driver.step(main) { |form| button.call(form, 'View details').press }
  driver.step(translate.call('Match details'), [27]) do |form|
    read_form.call(form)
    assert(form.fields.first.text.include?(record['evidence']['plan']['id']), 'Szczegóły zgubiły plan')
  end
  driver.step(main) { |form| button.call(form, 'Choose technical deadline').press }
  driver.step(translate.call('Technical local trial deadline'), [13]) do |form|
    read_form.call(form)
    verify_text.call(form.fields.first.text, translate.call('Technical policy: %{policy}') % {policy: f::T::LocalFixedTeamConnection::POLICY}, 'deadline/policy')
    date = Time.at(record['evidence']['plan']['matches'].first['windows'].first['closes'] - 60).getlocal
    controls = form.fields.grep(ListBox)
    assert_equal(5, controls.size)
    [date.year, date.month, date.day, date.hour, date.min].zip(controls).each_with_index do |(value, control), index|
      control.index = control.options.index(format(index.zero? ? '%04d' : '%02d', value)) || raise('Brak daty w kontrolce')
      control.trigger(:move)
    end
    form.index = form.fields.index(button.call(form, 'Use technical deadline'))
  end
  driver.step(main) do |form|
    button.call(form, 'Prepare local target').press; complete.call(form)
    view = hub.instance_variable_get(:@fixed_team_entry).controller.view
    assert_equal(:bound, view[:coordination][:state])
    target = view[:coordination][:target].to_h
    status = field.call(form, 'Fixed-team execution status').text
    [target['binding']['native_uuid'],target['receipt']['native_digest'],*%w[Ala Anna Bartek Beata]].each { |s| assert(status.include?(s), 'Niepełny stan celu') }
    verify_text.call(status, translate.call('Confirmed private local target. Only its creator is present; no player consent or tournament entry was recorded.'), 'target/boundary')
    verify_text.call(status, translate.call('Game: %{game}') % {game: target['binding']['game_id']}, 'target/game')
    verify_text.call(status, translate.call('Planned player: %{name}; account: %{account}; team: %{team}; seat: %{seat}') % target['binding']['players'].first.transform_keys(&:to_sym).merge(name: target['binding']['players'].first['username']), 'target/player')
    verify_text.call(status, translate.call('Public digest: %{digest}') % {digest: target['receipt']['request_digest']}, 'target/public-digest')
    verify_text.call(status, translate.call('Native options: %{options}') % {options: JSON.generate(target['native']['options'])}, 'target/options')
    read_form.call(form)
    button.call(form, 'Withdraw readiness').press; complete.call(form)
    assert_equal('withdrawn', hub.instance_variable_get(:@fixed_team_entry).controller.view[:current]['state'])
    button.call(form, 'Check original coordination').press; complete.call(form)
    coordination = hub.instance_variable_get(:@fixed_team_entry).controller.view[:coordination]
    assert_equal(:blocked, coordination[:state])
    assert_equal(:stale_grant, coordination[:reason])
    read_form.call(form)
  end
  driver.step(main, [27])
  driver.step(translate.call('Local tournament tests'), [27])
  hub.run
  driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  assert_equal(host_before, host_snapshot.call)
  assert(loader.loaded.keys.any? { |p| p.end_with?('local_fixed_team_execution_screen.rb') }, 'UI nie załadowano binarnie') if mode == 'binary'
  result = {mode: mode, language: language, host_language: Configuration.language, snapshots: snapshots,
    binary_loaded: loader.loaded, speech: SpeechOutput.calls.map(&:first), braille: NVDA.calls.map(&:first), forms: driver.forms.size,
    failures: failures, host_unchanged: true, missing_removed: missing ? removed : []}
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'native-localization.json'), JSON.pretty_generate(result))
  raise "Nieprzetłumaczone granice: #{failures.map { |r| r[:gate] }.inspect}" unless failures.empty?
  puts "PASS #{mode}/#{language}: #{driver.forms.size} formularzy; Hub→Ready→F1→Details→Deadline→target→Withdraw→historia; polski host"
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
  runtime.close
end
