# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja terminu U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
results = []
begin
  [:changed_window, :lease].each do |mode|
    driver = TournamentNativeDriver.new
    hub = T::LocalTestHub.new(**F.args(fixture))
    parent = selection = nil
    U.enter(driver)
    driver.step('Accepted fixed-team plans') do |form|
      parent = form
      F.button(form, 'Check status').press; U.complete(hub, form)
      selection = U.screen(hub).send(:selectors)
      F.button(form, 'Choose technical deadline').press
      if mode == :changed_window
        assert_equal(selection, U.screen(hub).send(:selectors))
        assert_equal(selection, U.screen(hub).instance_variable_get(:@deadline)[:selectors])
      else
        assert_equal(nil, U.screen(hub).instance_variable_get(:@deadline))
      end
    end
    driver.step('Technical local trial deadline', [13]) do |form|
      date = Time.at(fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes'] - 60).getlocal
      [date.year, date.month, date.day, date.hour, date.min].zip(%w[year month day hour minute]).each do |value, part|
        field = F.field(form, "End: #{part}")
        field.index = field.options.index(format(part == 'year' ? '%04d' : '%02d', value)); field.trigger(:move)
      end
      F.field(parent, 'Execution window').index = 1
      F.button(parent, 'Prepare local target').press
      assert_equal(nil, U.screen(hub).instance_variable_get(:@readiness_pending))
      U.screen(hub).controller.session.choose_actor('Anna') if mode == :lease
      form.index = form.fields.index(F.button(form, 'Use technical deadline'))
    end
    driver.step('Accepted fixed-team plans', [27]) if mode == :changed_window
    driver.step('Local tournament tests', [27])
    hub.run; driver.finish
    results << {mode: mode, original: selection}
  end
  %w[Ala Anna Bartek Beata].each do |actor|
    F.with_execution(fixture, actor) do |execution|
      F.select_execution(execution, fixture[:record]); assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  expires = fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes'] - 60
  reserve_calls = 0
  expire_during_io = Module.new do
    define_method(:reserve) do |**options|
      reserve_calls += 1
      fixture[:now] = expires
      super(**options)
    end
  end
  T::LocalFixedTeamCoordinationPort.prepend(expire_during_io)
  F.with_execution(fixture, 'Ala', expires_at: expires) do |execution|
    F.select_execution(execution, fixture[:record])
    refused = execution.request_match
    assert_equal(:blocked, refused[:state]); assert_equal(:not_all_ready, refused[:reason])
    assert_equal(1, reserve_calls, 'Nie osiągnięto bramki wygaśnięcia wewnątrz reserve')
    results << {mode: :expiry_during_operation, result: refused}
  end
  state_path = File.join(fixture[:plans], 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  state = JSON.parse(File.binread(state_path))
  assert_equal(1, state['executions'].size)
  assert_equal(expires, state['executions'].values.first['expires_at'])
  assert_equal(nil, state['executions'].values.first['grant'])
  assert_equal([], state['native']['sessions'])
  frozen = U.snapshot(fixture[:sandbox])
  F.with_execution(fixture, 'Ala', expires_at: expires + 30) do |execution|
    F.select_execution(execution, fixture[:record])
    retry_result = execution.request_match
    assert_equal(:unknown, retry_result[:state]); assert_equal(:port_unavailable, retry_result[:reason])
    assert_equal(results.last[:result][:operation_id], retry_result[:operation_id])
  end
  assert_equal(frozen, U.snapshot(fixture[:sandbox]), 'Nowy termin niejawnie odnowił wykonanie')
  assert_equal(1, reserve_calls)
  U.evidence('deadline-matrix', {results: results, state: state})
  puts 'PASS okno/lease pod modalem; wygaśnięcie w reserve, zero celu, brak renew/takeover i identyczny UUID przy ponowieniu'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
