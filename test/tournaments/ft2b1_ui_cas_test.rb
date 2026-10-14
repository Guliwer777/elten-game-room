# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja CAS U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
begin
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  U.enter(driver)
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press; U.complete(hub, form)
    assert_equal(0, U.screen(hub).controller.view[:current]['ready_revision'])
    original = nil
    F.with_execution(fixture, 'Ala') do |execution|
      F.select_execution(execution, fixture[:record])
      original = execution.declare(availability: 'ready', expected_revision: 0)
      assert_equal(:confirmed, original[:state])
    end
    frozen = U.snapshot(fixture[:sandbox])
    F.button(form, 'Withdraw readiness').press; U.complete(hub, form)
    view = U.screen(hub).controller.view
    assert_equal(:blocked, view[:operation][:state])
    assert_equal(:intent_conflict, view[:operation][:reason])
    assert_equal(original[:operation_id], view[:operation][:operation_id])
    assert_equal(1, view[:current]['ready_revision'])
    assert_equal('ready', view[:current]['state'])
    assert_equal(frozen, U.snapshot(fixture[:sandbox]), 'Stara rewizja wywołała nowy zapis')
    assert(F.field(form, 'Fixed-team execution status').text.include?('revision changed'), 'UI nie wyjaśnia odmowy starej rewizji')
    F.with_execution(fixture, 'Ala') do |execution|
      index = fixture[:record]['evidence']['plan']['matches'].index { |m| m['players'].none? { |p| p['account'] == 'ala' } }
      assert(index, 'Brak legalnego obcego meczu w fixture')
      F.select_execution(execution, fixture[:record], index)
      result = execution.declare(availability: 'ready', expected_revision: 0)
      assert_equal(:blocked, result[:state])
      assert_equal(:not_participant, result[:reason])
      assert_equal(nil, result[:operation_id])
      U.evidence('cas-foreign', {original: original, stale: view[:operation], foreign: result, foreign_request: execution.selection[:request].to_h})
    end
    assert_equal(frozen, U.snapshot(fixture[:sandbox]), 'Obcy mecz mutował stan')
  end
  U.leave(driver)
  hub.run; driver.finish
  puts 'PASS stara rewizja przez UI: pełny reason/UUID i brak store; legalny obcy mecz blokowany przed deklaracją'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
