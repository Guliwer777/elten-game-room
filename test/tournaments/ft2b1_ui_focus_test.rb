# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja fokusu U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
begin
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  parent = expected = status = nil
  presented = []
  phase = nil
  driver.on_resume = lambda do |form|
    next unless form.fields.first.header == 'Keyboard shortcuts'
    phase = :return
    assert(U.screen(hub).instance_variable_get(:@busy), 'Busy zwolniono w resume')
    parent.fields.first.index = 0
    F.field(parent, 'My fixed-team matches').index = 0
    F.field(parent, 'Execution window').index = 0
    status.index = status.check = 0
    parent.index = 0
    F.button(parent, 'Back').press
    F.button(parent, 'Ready').press
    F.button(parent, 'View details').press
    assert_equal(nil, U.screen(hub).instance_variable_get(:@readiness_pending))
  end
  trace = TracePoint.new(:call) do |event|
    if phase == :return && event.method_id == :focus && event.defined_class == EltenAPI::Controls::EditBox
      presented << {selection: U.screen(hub).send(:selectors), field: parent.index,
        index: status.index, check: status.check, text: status.text, busy: U.screen(hub).instance_variable_get(:@busy)}
    end
  end
  U.enter(driver)
  driver.step('Accepted fixed-team plans') do |form|
    parent = form
    F.button(form, 'Check status').press; U.complete(hub, form)
    form.fields.first.index = 1; form.fields.first.trigger(:move); U.complete(hub, form)
    matches = F.field(form, 'My fixed-team matches'); matches.index = 2; matches.trigger(:move); U.complete(hub, form)
    windows = F.field(form, 'Execution window'); windows.index = 1; windows.trigger(:move); U.complete(hub, form)
    expected = U.screen(hub).send(:selectors)
    status = F.field(form, 'Fixed-team execution status')
    status.index, status.check = 7, 11
    form.index = form.fields.index(status)
    status.on(:before_focus) do
      next unless phase == :return
      F.button(form, 'Ready').press; F.button(form, 'Back').press
      F.field(form, 'Execution window').index = 0
      assert(U.screen(hub).instance_variable_get(:@busy), 'Busy zwolniono w before_focus')
    end
    trace.enable(target_thread: nil)
    form.show_game_room_help
    trace.disable
    assert_equal(expected, U.screen(hub).send(:selectors), 'F1/resume/before_focus zmieniło okno/plan')
    assert_equal(1, presented.size, 'Powrót ma dokładnie jedną natywną prezentację, nie sam indeks')
    assert_equal({selection: expected, field: form.fields.index(status), index: 7, check: 11, text: status.text, busy: true}, presented.first)
    U.evidence('focus-return', presented)
    assert_equal(nil, U.screen(hub).instance_variable_get(:@readiness_pending))
  end
  driver.step('Keyboard shortcuts', [27])
  U.leave(driver)
  hub.run; driver.finish
  puts 'PASS F1: dwa plany, mecze, okna; busy w resume/before_focus, spójny kursor i pojedynczy control.focus'
ensure
  trace&.disable
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
