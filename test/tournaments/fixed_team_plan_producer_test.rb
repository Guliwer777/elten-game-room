# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_ft2b1_entry'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
language = ARGV.include?('--pl') ? 'pl' : 'en'
GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
if ARGV.include?('--binary')
  verbose, $VERBOSE = $VERBOSE, nil
  begin
    %w[local_fixed_team_plan_backend local_fixed_team_connection local_workspace local_fixed_team_plan_screen local_test_hub].each do |name|
      path = File.expand_path('../../lib/tournaments/' + name + '.rb', __dir__)
      Object.class_eval(File.binread(path), path)
    end
  ensure
    $VERBOSE = verbose
  end
end
large = ARGV.include?('--six') || ARGV.include?('--eight')
size = ARGV.include?('--eight') ? 4 : 3
names = %w[Ala Anna Bartek Beata Celina Cezary Dorota Daniel].take(size * 2)
if large
  require_relative '../../games/taboo'
  registry = GameRoomGames::Registry.new([GameRoomGames::Taboo])
end
directory = GameRoomTest::TemporaryDirectory.create('p')
fixture = large ? F.fixture(directory, accept_plan: false, game_id: 'taboo', registry: registry,
  names: names, players_per_match: size * 2) : F.fixture(directory, accept_plan: false)
program = fixture.fetch(:program)
owner = T::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(message) { raise message })
workspace = T::LocalWorkspace.new(program: program, registry: fixture[:registry], user: owner.method(:current),
  actor: 'Organizator', alert: ->(message) { raise message }, clock: -> { fixture[:now] })
begin
  assert(!File.exist?(File.join(fixture[:plans], 'fixed-teams-v1', 'sandbox-k02.json')), 'Fixture accepted a plan before UI')
  driver = TournamentNativeDriver.new
  input = large ? names.each_slice(size).map { |team| team.join(', ') }.join("\n") : "Anna, Ala\nBartek, Beata\nCelina, Cezary"
  team_caption = large ? L.call('Teams: %{count} accounts per line, separated by a comma') % {count: size} :
    L.call('Teams: two accounts per line, separated by a comma')
  driver.press(L.call('Tournament to plan'), 13) do |form|
    F.field(form, team_caption).set_text(input)
    form.index = form.fields.index(F.button(form, L.call('Preview fixed-team plan')))
  end
  driver.press(L.call('Tournament to plan'), 13) do |form|
    preview = F.field(form, L.call('Fixed-team plan preview')).text
    assert(preview.include?(large ? '1: Ala (team-001)' : '1: Anna (team-001)'), 'Explicit first seat missing from preview')
    assert(preview.include?('/ 2:'), 'Return legs missing')
    assert(!File.exist?(File.join(fixture[:plans], 'fixed-teams-v1', 'sandbox-k02.json')), 'Preview saved a plan')
    # Editing after preview must revoke acceptance, even through native Enter.
    changed = large ? input.sub('Ala, Anna', 'Anna, Ala') : input.sub('Anna, Ala', 'Ala, Anna')
    F.field(form, team_caption).set_text(changed)
    form.index = form.fields.index(F.button(form, L.call('Accept displayed plan')))
  end
  driver.press(L.call('Tournament to plan'), 13) do |form|
    assert(F.field(form, L.call('Fixed-team plan preview')).text.include?(L.call('Settings changed. Preview the plan again before accepting.')), 'Changed input accepted')
    form.index = form.fields.index(F.button(form, L.call('Preview fixed-team plan')))
  end
  driver.press(L.call('Tournament to plan'), 13) do |form|
    form.index = form.fields.index(F.button(form, L.call('Accept displayed plan')))
  end
  driver.press(L.call('Tournament to plan'), 13) do |form|
    assert(F.field(form, L.call('Fixed-team plan preview')).text.include?(L.call('Plan accepted. Open Fixed teams — local execution to check its matches.')), 'Acceptance missing')
    form.index = form.fields.index(F.button(form, L.call('Check plan acceptance')))
  end
  driver.step(L.call('Tournament to plan'), [27]) do |form|
    assert(F.field(form, L.call('Fixed-team plan preview')).text.include?(L.call('Plan accepted. Open Fixed teams — local execution to check its matches.')), 'Readback missing')
    if ARGV.include?('--dispatch-config')
      F.field(form, L.call('Maximum simultaneous tables')).set_text('2')
      F.button(form, L.call('Set tournament table limit')).press
      assert(F.field(form, L.call('Fixed-team plan preview')).text.include?('2'), 'Table limit not confirmed')
    end
  end
  T::LocalFixedTeamPlanScreen.new(program: program, workspace: workspace, owner: owner).run
  driver.finish
  # A fresh connection uses the same factory and sees the user-produced record.
  session = T::LocalReadinessSession.new
  session.choose_actor('Ala')
  entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
    owner_reader: owner.method(:current), actor: 'Ala', account_events: session.actor_events)
  participant = T::LocalWorkspace.new(program: program, registry: fixture[:registry], user: owner.method(:current),
    actor: 'Ala', alert: ->(message) { raise message }, clock: -> { fixture[:now] })
  connection = participant.fixed_team_connection(context: entry, lease: entry.capture, session: session)
  assert_equal(:accepted, connection.catalog[:reason])
  assert_equal(1, connection.catalog[:catalog].size)
  if large
    source = connection.catalog[:catalog].first['evidence']['source']
    assert_equal(2, source['source_version'])
    assert_equal(size, source['membership']['team_size'])
  end
  connection.close; entry.close; session.close
  puts 'PASS native producer: preview without write, changed settings blocked, accept/readback, shared execution catalog'
ensure
  connection&.close
  entry&.close
  session&.close
  program.finalize
  program.class.app_runtime.close
end
