# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja modalu U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
results = []
trace = nil
begin
  [:details, :deadline].each do |kind|
    driver = TournamentNativeDriver.new
    hub = F::T::LocalTestHub.new(**F.args(fixture))
    parent = modal = expected = nil
    phase = nil
    observed = []
    header = kind == :details ? 'Match details' : 'Technical local trial deadline'
    driver.on_resume = lambda do |form|
      next unless form.fields.first.header == 'Keyboard shortcuts'
      phase = :return
      assert(U.screen(hub).instance_variable_get(:@busy))
      assert(modal.instance_variable_get(:@hub_interaction).receiver.instance_variable_get(:@busy))
      modal.fields.first.index = modal.fields.first.check = 0
      modal.index = modal.fields.size - 1
      parent.fields.first.index = 0
      F.field(parent, 'Execution window').index = 0
      2.times { F.button(parent, 'Back').press; parent.accept_button.press }
    end
    trace = TracePoint.new(:call) do |event|
      next unless phase == :return
      observed << [event.self.equal?(modal.fields.first), modal.index, modal.fields.first.index, modal.fields.first.check, modal.fields.first.text]
    end
    U.enter(driver)
    driver.step('Accepted fixed-team plans') do |form|
      parent = form
      F.button(form, 'Check status').press; U.complete(hub, form)
      form.fields.first.index = 1; form.fields.first.trigger(:move); U.complete(hub, form)
      F.field(form, 'My fixed-team matches').index = 2; F.field(form, 'My fixed-team matches').trigger(:move); U.complete(hub, form)
      F.field(form, 'Execution window').index = 1; F.field(form, 'Execution window').trigger(:move); U.complete(hub, form)
      expected = U.screen(hub).send(:selectors)
      F.button(form, kind == :details ? 'View details' : 'Choose technical deadline').press
      assert_equal(expected, U.screen(hub).send(:selectors))
    end
    driver.step(header) do |form|
      modal = form
      field = form.fields.first
      form.index = 0; field.index, field.check = 7, 11
      text = field.text
      field.on(:before_focus) do
        next unless phase == :return
        field.index = field.check = 0
        form.cancel_button.press
        form.accept_button&.press
      end
      trace.enable(target: EltenAPI::Controls::EditBox.instance_method(:focus), target_thread: nil)
      form.game_room_hotkey_action(1).call
      trace.disable; phase = nil
      assert_equal([[true, 0, 7, 11, text]], observed, 'Zagnieżdżony F1 odczytał zmieniony caret przed przywróceniem')
      results << {kind: kind, observed: observed, selection: expected}
    end
    driver.step('Keyboard shortcuts', [27])
    driver.step(header, [27])
    driver.step('Accepted fixed-team plans') do |form|
      assert_equal(expected, U.screen(hub).send(:selectors))
      F.button(form, 'Ready').press; U.complete(hub, form)
      result = U.screen(hub).controller.view[:operation]
      assert_equal(:confirmed, result[:state])
      request = result[:receipt]['operation']['request']
      assert_equal(expected[:match_id], request['match_id'])
      assert_equal(expected[:window_id], request['window_id'])
      assert_equal(expected[:leg], request['leg'])
    end
    U.leave(driver)
    hub.run; driver.finish
    assert_equal([0, 0], [fixture[:program].managed_resources.size, fixture[:program].class.app_runtime.managed_resources.size])
  end
  U.evidence('nested-presentation', results)
  puts 'PASS details/deadline → F1 → resume/before_focus: jeden natywny odczyt spójnego caret, blokada Back/Enter, późniejsze Ready dokładnego wyboru'
ensure
  trace&.disable
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
