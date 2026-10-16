# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja owner U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
program = fixture[:program]
user = F::OWNER
alerts = []
hub = T::LocalTestHub.new(**F.args(fixture).merge(user: -> { user }, alert: ->(message) { alerts << message; user = F::OWNER }))
original_path = program.method(:data_path)
owner_reads = []
program.define_singleton_method(:data_path) do
  value = original_path.call
  user = 'InnyWlasciciel'
  owner_reads << hub.instance_variable_get(:@owner).current
  user = F::OWNER
  value
end
before = U.snapshot(fixture[:sandbox])
begin
  driver = TournamentNativeDriver.new
  U.enter(driver)
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press
    screen = U.screen(hub)
    work = screen.instance_variable_get(:@readiness_work)
    wait_background_work(work)
    form.update
    assert_equal(:not_read, screen.controller.reason, 'Przyjęto wynik po zmianie właściciela w I/O')
    assert_equal([], screen.controller.view[:tournaments])
  end
  driver.step('Local tournament tests') do |form|
    assert_equal(nil, hub.instance_variable_get(:@owner).current)
    F.button(form, 'Change test participant').press
    F.button(form, F::ACTION).press
    assert_equal('Ala', hub.instance_variable_get(:@workspace).actor)
  end
  driver.step('Local tournament tests', [27])
  hub.run; driver.finish
  assert_equal([nil], owner_reads)
  assert(alerts.all? { |text| text.include?('account changed') })
  assert_equal(before, U.snapshot(fixture[:sandbox]))
  assert_equal([0, 0], [program.managed_resources.size, program.class.app_runtime.managed_resources.size])
  U.evidence('owner-io', {owner_reads: owner_reads, alerts: alerts, before: before, after: U.snapshot(fixture[:sandbox])})
  puts 'PASS właściciel plików inny od aktora; zmiana podczas data_path/I/O zatrzaśnięta mimo powrotu konta, brak następnych okien/zapisów'
ensure
  program.define_singleton_method(:data_path, original_path)
  program.finalize; program.class.app_runtime.close
end
