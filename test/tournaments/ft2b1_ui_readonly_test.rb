# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja readonly U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
results = []
[:healthy, :empty, :outsider, :io_error].each_with_index do |mode, index|
  fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE')), index.to_s))
  File.delete(fixture[:plan_file]) if mode == :empty
  mutations = []
  traces = [[T::LocalFixedTeamPlanBackend, :accept], [T::LocalFixedTeamReadinessPort, :store],
    [T::LocalFixedTeamCoordinationPort, :reserve], [T::LocalFixedTeamCoordinationPort, :create_bind],
    [GameRoomTransport, :create_room]].map do |owner, method|
    observer = TracePoint.new(:call) { |event| mutations << [event.defined_class.name, event.method_id, Thread.current.object_id] }
    observer.enable(target: owner.instance_method(method), target_thread: nil)
    observer
  end
  before = U.snapshot(fixture[:sandbox])
  begin
    driver = TournamentNativeDriver.new
    hub = T::LocalTestHub.new(**F.args(fixture))
    U.enter(driver, mode == :outsider ? 'Obcy' : 'Ala')
    driver.step('Accepted fixed-team plans') do |form|
      F.button(form, 'Check status').press; U.complete(hub, form)
      case mode
      when :empty
        assert_equal(:no_accepted_plan, U.screen(hub).controller.reason)
        assert_equal(0, form.fields.first.options.size)
        assert(F.field(form, 'Fixed-team execution status').text.include?('No accepted fixed-team plan.'))
      when :outsider
        assert_equal(:no_membership, U.screen(hub).controller.reason)
        assert_equal(0, form.fields.first.options.size)
        assert(F.field(form, 'Fixed-team execution status').text.include?('No confirmed registration'))
      when :io_error
        form.fields.first.index = 1; form.fields.first.trigger(:move); U.complete(hub, form)
        selection = U.screen(hub).send(:selectors)
        view = U.screen(hub).controller.view
        connection = U.screen(hub).controller.instance_variable_get(:@connection)
        storage = connection.instance_variable_get(:@backend).instance_variable_get(:@storage)
        storage.define_singleton_method(:read_document) { raise IOError, 'Awaria kompletnego odczytu' }
        F.button(form, 'Check status').press; U.complete(hub, form)
        assert_equal(:read_failed, U.screen(hub).controller.reason)
        assert_equal(view, U.screen(hub).controller.view)
        assert_equal(selection, U.screen(hub).send(:selectors))
        assert(F.field(form, 'Fixed-team execution status').text.include?('could not be read completely'))
      end
      # Explicit local admission/start controls exist; merely reading the screen
      # must not invoke them. The mutation trace below enforces that boundary.
      assert(form.fields.grep(Button).none? { |b| b.label.match?(/\A(Invite|Join)/) }, 'Unexpected real invitation action in local test')
      form.game_room_hotkey_action(1).call
    end
    driver.step('Keyboard shortcuts', [27])
    driver.step('Accepted fixed-team plans', [13]) { |form| form.index = 0 }
    driver.step('Match details', [27]) if [:healthy, :io_error].include?(mode)
    U.leave(driver)
    hub.run; driver.finish
    assert_equal([], mutations, 'Odczyt/Enter/F1/refresh wywołały mutację biznesową')
    assert_equal(before, U.snapshot(fixture[:sandbox]), 'Readonly zmieniło rzeczywiste bajty')
    assert_equal([0, 0], [fixture[:program].managed_resources.size, fixture[:program].class.app_runtime.managed_resources.size])
    results << {mode: mode, mutations: mutations, before: before, after: U.snapshot(fixture[:sandbox])}
  ensure
    traces.each(&:disable)
    fixture[:program].finalize; fixture[:program].class.app_runtime.close
  end
end
U.evidence('readonly', results)
puts 'PASS zdrowy/pusty/obcy/błąd I/O: konkretne powody, retain, readonly Enter/F1/refresh, zero mutacji na wszystkich wątkach'
