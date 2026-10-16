# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja katalogu U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
begin
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  U.enter(driver)
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press; U.complete(hub, form)
    assert_equal(2, form.fields.first.options.size, 'Alias pomnożył katalog')
    form.fields.first.index = 1; form.fields.first.trigger(:move); U.complete(hub, form)
    matches = F.field(form, 'My fixed-team matches')
    matches.index = 2; matches.trigger(:move); U.complete(hub, form)
    windows = F.field(form, 'Execution window')
    windows.index = 1; windows.trigger(:move); U.complete(hub, form)
    screen = U.screen(hub)
    selected = screen.send(:selectors)
    view = screen.controller.view
    before = U.snapshot(fixture[:sandbox])
    plan_bytes = File.binread(fixture[:plan_file])
    File.binwrite(fixture[:plan_file], '{"broken":true}')
    error = nil
    begin
      F.button(form, 'Check status').press; U.complete(hub, form)
    rescue Exception => caught
      error = caught
    end
    U.evidence('catalog-error', {error: error && [error.class.name, error.message], selected: selected, after: screen.send(:selectors)})
    assert_equal(nil, error, 'Uszkodzenie katalogu nie może wyrzucać użytkownika z ostatniego zdrowego widoku')
    assert_equal(:sandbox_corrupt, screen.controller.reason)
    assert_equal(view, screen.controller.view, 'Zmieniono ostatni zdrowy model')
    assert_equal(selected, screen.send(:selectors), 'Rozdzielono kursor i model')
    status = F.field(form, 'Fixed-team execution status').text
    assert(status.include?('damaged') && status.include?('retained'), 'Brak konkretnego wyjaśnienia korupcji')
    assert_equal('{"broken":true}', File.binread(fixture[:plan_file]), 'Odczyt naprawił plik za użytkownika')
    File.binwrite(fixture[:plan_file], plan_bytes)
    assert_equal(before, U.snapshot(fixture[:sandbox]))
  end
  U.leave(driver)
  hub.run; driver.finish
  puts 'PASS dwa legalne FT1 z aliasami; korupcja katalogu zachowuje model, plan/mecz/okno i konkretne wyjaśnienie'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
