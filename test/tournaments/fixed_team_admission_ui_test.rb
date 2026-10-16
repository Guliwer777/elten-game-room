# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
if ARGV.include?('--binary')
  verbose, $VERBOSE = $VERBOSE, nil
  begin
    %w[local_fixed_team_admission local_fixed_team_execution_storage local_fixed_team_execution local_fixed_team_coordination_port local_fixed_team_connection local_fixed_team_entry local_fixed_team_native_endpoint local_fixed_team_execution_screen].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
fixture = F.fixture(GameRoomTest::TemporaryDirectory.create('u'))
record = fixture[:record]
begin
  %w[Ala Anna Bartek Beata].each do |actor|
    F.with_execution(fixture, actor) do |execution|
      F.select_execution(execution, record)
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  deadline = record['evidence']['plan']['matches'].first['windows'].first['closes'] - 60
  F.with_execution(fixture, 'Ala', expires_at: deadline) do |execution|
    F.select_execution(execution, record)
    assert_equal(:bound, execution.request_match[:state])
  end
  driver = TournamentNativeDriver.new
  hub = T::LocalTestHub.new(**F.args(fixture))
  complete = lambda do |form|
    2.times do
      screen = hub.instance_variable_get(:@fixed_team_entry)
      work = screen.instance_variable_get(:@readiness_work)
      wait_background_work(work, timeout: 30) if work && work.busy?
      form.update
    end
  end
  driver.open_test_participant
  driver.step(L.call('Choose a test participant'), [13]) do |form|
    F.field(form, L.call('Test participant name')).set_text('Anna')
    form.index = form.fields.index(F.button(form, L.call('Use test participant')))
  end
  driver.step(L.call('Local tournament tests'), [13]) { |form| form.index = form.fields.index(F.button(form, L.call(F::ACTION))) }
  driver.step(L.call('Accepted fixed-team plans')) do |form|
    F.button(form, L.call('Check status')).press; complete.call(form)
    F.button(form, L.call('Confirm local match entry')).press; complete.call(form)
    assert_equal(nil, hub.instance_variable_get(:@fixed_team_entry).controller.view[:admission])
    F.button(form, L.call('Check local match entry')).press; complete.call(form)
    text = F.field(form, L.call('Fixed-team execution status')).text
    assert(text.include?(L.call('Selected local target: %{native}; table: %{table}').split('%{native}').first), 'No exact target before consent')
    F.button(form, L.call('Consent to the selected local match')).press; complete.call(form)
    own = hub.instance_variable_get(:@fixed_team_entry).controller.view[:admission]
    assert_equal(:confirmed, own[:state])
    assert_equal(nil, own[:status]['entry'])
    assert_equal(1, own[:status]['participants'].size)
    F.button(form, L.call('Confirm local match entry')).press; complete.call(form)
    own = hub.instance_variable_get(:@fixed_team_entry).controller.view[:admission]
    assert_equal('joined', own[:status]['entry']['status'])
    assert(F.field(form, L.call('Fixed-team execution status')).text.include?(L.call('Confirmed seat: %{seat}; team: %{team}').split('%{seat}').first), 'Missing role receipt')
    matches = F.field(form, L.call('My fixed-team matches'))
    matches.index = 1; matches.trigger(:move); complete.call(form)
    assert_equal(nil, hub.instance_variable_get(:@fixed_team_entry).controller.view[:admission])
  end
  driver.step(L.call('Accepted fixed-team plans'), [27])
  driver.step(L.call('Local tournament tests'), [27])
  hub.run
  driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  puts 'PASS native UI: exact target read, separate consent/entry, confirmed seat, selection isolation'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
