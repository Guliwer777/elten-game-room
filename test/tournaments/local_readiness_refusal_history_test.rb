# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
extend GameRoomTest::Assertions
H = TournamentLocalHubTest
T = GameRoomTournaments
mode = ARGV.first || 'removed'
raise 'Nieznana odmowa źródła' unless %w[removed conflict read_failed missing_publication].include?(mode)
GameRoomLocalization.boot(settings: {'interface_language'=>'en','known_languages'=>['en']})
Dir.mktmpdir('refusal-history-',ENV.fetch('TMPDIR')) do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  now = 201
  alerts = []
  hub = T::LocalTestHub.new(**H.args(program:program,clock:-> {now},alert:->(text) {alerts << text}))
  driver = TournamentNativeDriver.new
  screen = nil
  complete = ->(form) do
    work = screen.instance_variable_get(:@readiness_work)
    wait_background_work(work) if work && work.busy?
    form.update
  end
  driver.open_test_participant
  driver.step('Choose a test participant',[13]) do |form|
    H.field(form,'Test participant name').set_text('Alicja')
    form.index = form.fields.index(H.button(form,'Use test participant'))
  end
  driver.step('Local tournament tests',[13]) { |form|form.index = form.fields.index(H.button(form,'My matches — readiness and coordination')) }
  driver.step('My tournaments') do |form|
    screen = hub.instance_variable_get(:@match_entry)
    H.button(form,'Check status').press; complete.call(form)
    H.button(form,'Prepare local test plan').press; complete.call(form)
  end
  driver.step('Local test plan',[13]) { |form|form.index = form.fields.index(H.button(form,'Accept local test plan')) }
  driver.step('My tournaments') do |form|
    complete.call(form)
    H.button(form,'Ready').press; complete.call(form)
    prior = screen.instance_variable_get(:@readiness_state)
    assert_equal(:confirmed,prior[:operation][:state])
    uuid = prior[:operation][:operation_id]
    plan = prior[:plan_id]
    path = Dir.glob('tournament-local-test-*/tables/*.json',base:directory).fetch(0)
    File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'publication-before-removal.bin'),File.binread(File.join(directory,path)))
    workspace = hub.instance_variable_get(:@workspace)
    expected_reason, expected_message = case mode
    when 'removed'
      File.delete(File.join(directory,path))
      [:no_membership, 'No confirmed registration for this test participant.']
    when 'conflict'
      view = screen.controller.view
      operation = workspace.load.fetch('operations').find { |row| row['account']=='alicja' && !row['eligible_ids'].empty? }
      other = view[:tournaments].find { |row| row['__id'] != operation['tournament_id'] }
      now = 150
      workspace.instance_variable_get(:@provider).insert_row('tournament_registrations',
        T::RegistrationProjection.join_values(tournament_id:other['__id'],operation_key:operation['operation_key']))
      now = 201
      [:unresolved_source_diagnostics, 'The registration source contains unresolved conflicts.']
    when 'read_failed'
      File.binwrite(File.join(directory,path),'{')
      [:read_failed, 'The status could not be read completely.']
    when 'missing_publication'
      original_load = workspace.method(:entry_load)
      workspace.define_singleton_method(:entry_load) do |**options|
        result = original_load.call(**options)
        File.delete(File.join(directory,path))
        result
      end
      [:missing_publication, 'The publication is no longer confirmed.']
    end
    effects = []
    trace = TracePoint.new(:call) do |event|
      effects << event.method_id if event.defined_class == T::LocalReadinessBackend && [:accept,:store].include?(event.method_id)
    end
    trace.enable do
      H.button(form,'Check status').press; complete.call(form)
      assert_equal(expected_reason,screen.controller.reason)
      status = H.field(form,'Readiness and coordination').text
      File.write(File.join(ENV.fetch('ENTRY_EVIDENCE'),'history-status.json'),JSON.pretty_generate({uuid:uuid,plan:plan,status:status}),encoding:'UTF-8')
      assert(status.include?(expected_message),'Brak bieżącego powodu odmowy')
      assert(status.include?('Own readiness: ready; revision: 1') && status.include?(uuid) && status.include?(plan),
        'Powód odmowy lub odświeżenie skasowały potwierdzony stan, plan albo znany UUID')
      assert(H.field(form,'Readiness operations').options.any? { |text|text.include?(uuid) },'Utracona historyczna operacja')
      before_files = TournamentMatchEntryTest.files(directory)
      ['Prepare local test plan','Ready','Withdraw readiness'].each do |name|
        H.button(form,name).press
        assert(!screen.instance_variable_get(:@readiness_pending),'Odmowa pozwoliła na nowego workera zapisu')
        assert(H.field(form,'Readiness and coordination').text.include?(uuid),'Odmowa skasowała znany UUID')
      end
      assert_equal(before_files,TournamentMatchEntryTest.files(directory),'Odmowa zmieniła pliki')
      H.button(form,'Read selected local record').press; complete.call(form)
      H.button(form,'Check uncertain operation').press; complete.call(form)
      assert(H.field(form,'Readiness and coordination').text.include?(uuid),'Readback nie użył pierwotnego UUID')
      assert_equal(:confirmed,screen.instance_variable_get(:@readiness_state)[:operation][:state])
    end
    assert_equal([],effects,'Historyczny odczyt wykonał accept/store')
    connection = screen.controller.instance_variable_get(:@readiness_connection)
    backend = connection.instance_variable_get(:@backend)
    program_error = NoMethodError.new('Nie maskuj błędu programu w odczycie')
    original = backend.method(:plans)
    backend.define_singleton_method(:plans) {raise program_error}
    begin
      H.button(form,'Read selected local record').press
      error = assert_raises(NoMethodError) {complete.call(form)}
      assert_equal(program_error,error,'Zastąpiono ProgramError')
    ensure
      backend.define_singleton_method(:plans,original)
    end
  end
  driver.step('My tournaments',[27])
  driver.step('Local tournament tests',[27])
  hub.run;driver.finish
  assert_equal(0,program.managed_resources.size)
  assert_equal(0,program.class.app_runtime.managed_resources.size)
end
puts 'PASS odmowa po utracie źródła: gotowość/plan/UUID i historyczny readback bez nowego accept/store; ProgramError propaguje'
