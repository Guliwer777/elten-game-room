# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja skutku U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
module URefreshFailure
  def declare(**options)
    super.tap { |result| @u_confirmed = result }
  end
  def current
    if @u_confirmed && @u_confirmed[:state] == :confirmed
      raise IOError, 'Kontrolowana awaria odczytu po potwierdzonym Ready'
    end
    super
  end
end
F::T::LocalFixedTeamExecution.prepend(URefreshFailure)
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
begin
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  U.enter(driver)
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press; U.complete(hub, form)
    F.button(form, 'Ready').press; U.complete(hub, form)
    view = U.screen(hub).controller.view
    receipt = view.fetch(:operation).fetch(:receipt)
    assert_equal(:confirmed, view[:operation][:state])
    assert_equal(receipt['result'].slice('state', 'ready_revision', 'server_time'), view[:current], 'Awaria refresh pozostawiła stary stan zamiast potwierdzonego skutku')
    status = F.field(form, 'Fixed-team execution status').text
    assert(status.include?(view[:operation][:operation_id]) && status.include?('ready') && status.include?('could not be read'), 'Brak UUID, skutku lub ostrzeżenia po potwierdzeniu')
    F.with_execution(fixture, 'Ala') do |execution|
      F.select_execution(execution, fixture[:record], history: true)
      assert_equal(view[:current], execution.current[:current])
      assert_equal(1, execution.history.size)
      assert_equal(receipt, execution.reconcile_readiness(operation_id: view[:operation][:operation_id])[:receipt])
    end
    U.evidence('confirmed-refresh', {receipt: receipt, current: view[:current], status: status})
  end
  U.leave(driver)
  hub.run; driver.finish
  puts 'PASS potwierdzone Ready i pełny receipt pozostają w widoku po błędzie refresh; readback ten sam UUID'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
