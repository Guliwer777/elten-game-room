# encoding: UTF-8
require_relative '../support/tournament_ft2b1_fix1'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja natywnych dowodów R01'); super(value, message); end
X = TournamentFT2B1Fix1
F = TournamentFT2B1
U = TournamentFT2B1UI
T = GameRoomTournaments
base = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE')))
observer = X::Observer.new
begin
  ui = Thread.current.object_id
  ui_result = X.positive(File.join(base, 'positive-ui'))
  worker = Thread.new { X.positive(File.join(base, 'positive-worker')) }
  worker_result = worker.value
  worker.join
  positives = observer.calls.dup
  observer.targets.each do |owner, method|
    [ui, worker.object_id].each do |thread|
      assert(positives.any? { |r| r[:owner] == owner.name && r[:method] == method && r[:thread] == thread }, "Brak kontroli #{owner}##{method}/#{thread}")
    end
  end
  U.evidence('business-positive', {ui: ui, worker: worker.object_id, joined: !worker.alive?, calls: positives, ui_result: ui_result, worker_result: worker_result})
ensure
  observer.close
end

fixture = U.fixture(File.join(base, 'readonly'))
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
observer = X::Observer.new
begin
  driver = TournamentNativeDriver.new
  hub = T::LocalTestHub.new(**F.args(fixture))
  saved = details_before = details_after = corrupt = previous = nil
  U.enter(driver)
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press; U.complete(hub, form)
    form.fields.first.index = 1; form.fields.first.trigger(:move); U.complete(hub, form)
    matches = F.field(form, 'My fixed-team matches')
    matches.index = 2; matches.trigger(:move); U.complete(hub, form)
    windows = F.field(form, 'Execution window')
    windows.index = 1; windows.trigger(:move); U.complete(hub, form)
    status = F.field(form, 'Fixed-team execution status')
    status.index = 7; status.check = 11
    form.index = 1
    screen = U.screen(hub)
    assert(form.fields.grep(Button).none? { |button| button.label.match?(/\A(Start|Invite|Join|Consent)/) }, 'Niezlecona kontrolka startu lub zgody')
    previous = screen.controller.view
    saved = X.selection(screen)
    details_before = X.modal(driver, screen)
    assert_equal(saved, X.selection(screen))
    document = JSON.parse(File.binread(fixture[:plan_file]))
    document['records'].first['evidence']['plan_digest'] = '0' * 64
    File.binwrite(fixture[:plan_file], JSON.generate(document))
    corrupt = U.snapshot(fixture[:sandbox])
    F.button(form, 'Check status').press; U.complete(hub, form)
    assert_equal(:sandbox_corrupt, screen.controller.reason)
    assert(screen.controller.view.equal?(previous))
    failures = []
    failures << {phase: 'po odczycie korupcji', expected: saved, actual: X.selection(screen)} unless saved == X.selection(screen)
    expected_status = ['Local test — this computer only', 'Test actor: Ala', 'Own readiness: unknown; revision: 0',
      'The accepted fixed-team storage is damaged or incompatible. The last valid view is retained; no data was replaced.',
      'Ready is not consent or entry. This local screen does not invite players or start games. Planned players are not present participants.'].join("\r\n")
    assert_equal(expected_status, status.text)
    details_after = X.modal(driver, screen)
    expected_details = details_before[:text].sub("Ready is not consent", "The accepted fixed-team storage is damaged or incompatible. The last valid view is retained; no data was replaced.\r\nReady is not consent")
    assert_equal(expected_details, details_after[:text], 'Pełny tekst prawdziwego modalu po korupcji')
    assert_equal(details_before.values_at(:caret, :check, :field), details_after.values_at(:caret, :check, :field))
    assert_equal(details_before[:text], details_before[:control].text, 'Stary EditBox zmieniony po korupcji')
    failures << {phase: 'po Szczegółach', expected: saved, actual: X.selection(screen)} unless saved == X.selection(screen)
    assert_equal(corrupt, U.snapshot(fixture[:sandbox]))
    U.evidence('modal-retention', {before: X.modal_value(details_before), after: X.modal_value(details_after), expected_details: expected_details,
      selection_before: saved, selection_after: X.selection(screen), exact_status: status.text, same_model: true, disk_unchanged: true, failures: failures})
    @fix1_retention_failures = failures
  end
  U.leave(driver)
  hub.run; driver.finish
  assert_equal([], observer.calls, 'Sam odczyt uruchomił mutację biznesową')
  assert_equal(corrupt, U.snapshot(fixture[:sandbox]))
  assert_equal([0, 0], [fixture[:program].managed_resources.size, fixture[:program].class.app_runtime.managed_resources.size])
  U.evidence('business-readonly', {calls: observer.calls, registries: [0, 0], no_start_control: true})
  assert_equal([], @fix1_retention_failures, 'Retencja caretu Status nie może być zaliczona na podstawie samego modalu')
  puts 'PASS realne Szczegóły przed/po korupcji, pełny Status, selekcja/caret, zero biznesowe i dodatnia kontrola UI/worker'
ensure
  observer.close
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
