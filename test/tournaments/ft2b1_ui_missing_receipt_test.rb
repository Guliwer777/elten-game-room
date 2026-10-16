# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja braku receipt U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
begin
  %w[Ala Anna Bartek Beata].each do |actor|
    F.with_execution(fixture, actor) do |execution|
      F.select_execution(execution, fixture[:record])
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  deadline = fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes'] - 60
  original = nil
  F.with_execution(fixture, 'Ala', expires_at: deadline) do |execution|
    F.select_execution(execution, fixture[:record]); original = execution.request_match
  end
  assert_equal(:bound, original[:state])
  unavailable = Module.new do
    define_method(:lookup) do |**options|
      receipt = super(**options)
      raise T::CoordinationContract::PortUnavailable, 'Nieobecna odpowiedź receipt' if options[:kind] == 'create_bind'
      receipt
    end
  end
  T::LocalFixedTeamCoordinationPort.prepend(unavailable)
  before = U.snapshot(fixture[:sandbox])
  observations = []
  driver = TournamentNativeDriver.new
  hub = T::LocalTestHub.new(**F.args(fixture))
  U.enter(driver)
  2.times do |round|
    if round > 0
      driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(F.button(form, F::ACTION)) }
    end
    driver.step('Accepted fixed-team plans') do |form|
      F.button(form, 'Check status').press; U.complete(hub, form)
      F.button(form, 'Check original coordination').press; U.complete(hub, form)
      result = U.screen(hub).controller.view[:coordination]
      assert_equal(:unknown, result[:state]); assert_equal(:port_unavailable, result[:reason])
      assert_equal(original[:operation_id], result[:operation_id])
      F.button(form, 'Choose technical deadline').press
    end
    driver.step('Technical local trial deadline', [13]) do |form|
      date = Time.at(deadline).getlocal
      [date.year, date.month, date.day, date.hour, date.min].zip(%w[year month day hour minute]).each do |value, part|
        field = F.field(form, "End: #{part}")
        field.index = field.options.index(format(part == 'year' ? '%04d' : '%02d', value)); field.trigger(:move)
      end
      form.index = form.fields.index(F.button(form, 'Use technical deadline'))
    end
    driver.step('Accepted fixed-team plans') do |form|
      2.times do
        F.button(form, 'Prepare local target').press; U.complete(hub, form)
        result = U.screen(hub).controller.view[:coordination]
        assert_equal(:unknown, result[:state]); assert_equal(:port_unavailable, result[:reason])
        assert_equal(original[:operation_id], result[:operation_id])
        assert_equal(nil, result[:binding])
        observations << result
      end
      assert_equal(before, U.snapshot(fixture[:sandbox]), 'Brak receipt otworzył nowy intent/create')
    end
    driver.step('Accepted fixed-team plans', [27])
  end
  driver.step('Local tournament tests', [27])
  hub.run; driver.finish
  U.evidence('missing-receipt', {original: original[:target].to_h, attempts: observations, before: before, after: U.snapshot(fixture[:sandbox])})
  puts 'PASS brak receipt: kolejne Prepare i ponowne wejście uzgadniają oryginalny UUID, pełne dane bez zmian'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
