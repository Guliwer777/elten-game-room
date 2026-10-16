# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja historii U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
results = {}
begin
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  %w[Anna Bartek Beata Ala].each_with_index do |actor, index|
    U.enter(driver, actor)
    driver.step('Accepted fixed-team plans') do |form|
      F.button(form, 'Check status').press; U.complete(hub, form)
      F.button(form, 'Ready').press; U.complete(hub, form)
      effect = U.screen(hub).controller.view[:operation]
      assert_equal(:confirmed, effect[:state])
      assert_equal(actor.downcase, effect[:receipt]['operation']['account'])
      assert_equal(1, effect[:receipt]['result']['ready_revision'])
      results[actor] = effect
    end
    driver.step('Accepted fixed-team plans', [27]) unless actor == 'Ala'
  end
  driver.step('Accepted fixed-team plans') { |form| F.button(form, 'Choose technical deadline').press }
  driver.step('Technical local trial deadline', [13]) do |form|
    date = Time.at(fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes'] - 60).getlocal
    [date.year, date.month, date.day, date.hour, date.min].zip(%w[year month day hour minute]).each do |value, part|
      field = F.field(form, "End: #{part}")
      field.index = field.options.index(format(part == 'year' ? '%04d' : '%02d', value)); field.trigger(:move)
    end
    form.index = form.fields.index(F.button(form, 'Use technical deadline'))
  end
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Prepare local target').press; U.complete(hub, form)
    target = U.screen(hub).controller.view[:coordination]
    assert_equal(:bound, target[:state])
    results['target'] = target[:target].to_h
    F.button(form, 'Withdraw readiness').press; U.complete(hub, form)
    withdrawn = U.screen(hub).controller.view[:operation]
    assert_equal(:confirmed, withdrawn[:state])
    assert_equal(2, withdrawn[:receipt]['result']['ready_revision'])
    assert_equal(1, withdrawn[:receipt]['result']['invalidated_grants'].size)
    results['withdrawn'] = withdrawn
    frozen = U.snapshot(fixture[:sandbox])
    F.button(form, 'Check original coordination').press; U.complete(hub, form)
    assert_equal(:blocked, U.screen(hub).controller.view[:coordination][:state])
    assert_equal(:stale_grant, U.screen(hub).controller.view[:coordination][:reason])
    assert_equal(frozen, U.snapshot(fixture[:sandbox]), 'Historyczny odczyt po Withdraw mutuje stan')
    fixture[:now] = fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes'] + 1
    F.button(form, 'Check original coordination').press; U.complete(hub, form)
    assert_equal(:blocked, U.screen(hub).controller.view[:coordination][:state])
    assert_equal(:stale_grant, U.screen(hub).controller.view[:coordination][:reason])
    F.button(form, 'Prepare local target').press; U.complete(hub, form)
    assert_equal(:invalid_technical_deadline, U.screen(hub).controller.view[:coordination][:reason])
    assert_equal(frozen, U.snapshot(fixture[:sandbox]), 'Termin/grant odnowił się automatycznie')
    workspace = F::T::LocalWorkspace.new(**F.args(fixture).reject { |k, _| k == :confirm }, actor: 'Inny')
    draft = {'name' => 'Inna publikacja', 'game_id' => 'spades', 'game_options' => F::REGISTRY.build('spades').normalize_options({'team_size' => 2}),
      'format' => 'round_robin', 'rematch' => true, 'players_per_match' => 4, 'pairing' => 'all_combinations', 'participants' => [],
      'windows' => [{'date' => '2026-10-16', 'start' => '12:00', 'end_date' => '2026-10-16', 'end' => '21:00'}]}
    assert_equal('confirmed', workspace.publish(draft: draft, intent_id: 'zmiana-zrodla', rules: 'Lokalne.', registration_opens_at: fixture[:now] - 1, registration_closes_at: fixture[:now] + 60, timezone: 'local_test:system')['status'])
    frozen = U.snapshot(fixture[:sandbox])
    error = nil
    begin
      F.button(form, 'Ready').press; U.complete(hub, form)
    rescue Exception => caught
      error = caught
    end
    assert_equal(nil, error, 'source_changed musi blokować zapis i pozostawić dostępną historię')
    assert_equal(:source_changed, U.screen(hub).controller.reason)
    assert(F.field(form, 'Fixed-team execution status').text.include?('source changed'), 'Brak wyjaśnienia source_changed')
    F.button(form, 'Check original coordination').press; U.complete(hub, form)
    assert_equal(:blocked, U.screen(hub).controller.view[:coordination][:state])
    assert_equal(:stale_grant, U.screen(hub).controller.view[:coordination][:reason])
    assert_equal(frozen, U.snapshot(fixture[:sandbox]), 'Current odmówił, ale coś zapisano')
    U.evidence('history-full', results)
  end
  U.leave(driver)
  hub.run; driver.finish
  puts 'PASS cztery jawne osoby w Hubie; Ready/Withdraw CAS/UUID, unieważniony grant, expiry, source_changed i historyczny exact target'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
