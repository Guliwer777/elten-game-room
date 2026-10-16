# encoding: UTF-8
require_relative '../support/tournament_ft2b1_entry'
include GameRoomTest::Assertions
F = TournamentFT2B1
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE')))
fixture = F.fixture(directory)
program = fixture.fetch(:program)
begin
  driver = TournamentNativeDriver.new
  F.actor(driver, 'Ala')
  driver.step('Local tournament tests', [27]) do |form|
    assert(form.fields.grep(Button).any? { |item| item.label == F::ACTION }, 'Zdrowy Hub nie udostępnia wejścia zaakceptowanego FT1')
    assert(form.fields.first.text.include?('Test actor: Ala'), 'Nie wybrano świadomie aktora')
  end
  F::T::LocalTestHub.new(**F.args(fixture)).run
  driver.finish
  puts 'PASS Hub: legalne publication/join/accept FT1, właściciel != aktor, nowa kontrolka'
ensure
  program.finalize
  program.class.app_runtime.close
end
