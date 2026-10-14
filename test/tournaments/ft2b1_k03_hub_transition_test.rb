# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
require 'digest'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
mode = ARGV.fetch(0, 'healthy')
raise 'Nieznany tryb C09' unless %w[healthy actor_aba backend_aba owner program runtime].include?(mode)
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE')))
fixture = F.fixture(directory)
fixture[:program].finalize
fixture[:program].class.app_runtime.close
module Log
  def self.debug(_message); end
  def self.warning(_message); end
  def self.info(_message); end
end
require EltenTestHost.file('src/eapi/program.rb')
manifest = Struct.new(:id, :namespace_name, :execution).new('99d0c035-2e6d-4528-bfd9-f5ac2542dfe1', 'K03Probe', Programs::Execution::Spec.new({'backend' => 'runtime'}))
runtime = Programs::Runtime.new(entry_id: "k03-#{mode}", root: ENV.fetch('FT2_SCRATCH'), manifest: manifest)
klass = Programs.with_runtime(runtime) { Class.new(::Program) }
klass.instance_variable_set(:@app_runtime, runtime)
program = klass.new
program.define_singleton_method(:data_path) { directory }
fixture[:program] = program
user = F::OWNER
alerts = []
hub = T::LocalTestHub.new(**F.args(fixture).merge(user: -> { user }, alert: ->(message) { alerts << message }))
driver = TournamentNativeDriver.new
old = old_work = old_worker = old_session = old_identity = old_view = nil
current = current_session = current_work = current_worker = nil
old_entered, old_release, entered, release = Queue.new, Queue.new, Queue.new, Queue.new
snapshot = lambda do
  Dir.glob('**/*', base: directory).select { |rel| File.file?(File.join(directory, rel)) }.sort.to_h do |rel|
    [rel, Digest::SHA256.file(File.join(directory, rel)).hexdigest]
  end
end
complete = lambda do |screen, form|
  2.times do
    work = screen.instance_variable_get(:@readiness_work)
    wait_background_work(work) if work&.busy?
    form.update
  end
end
before = nil
F.actor(driver, 'Ala')
driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(F.button(form, 'My matches — readiness and coordination')) }
driver.step('My tournaments') do |form|
  old = hub.instance_variable_get(:@match_entry)
  assert_equal(T::MatchEntry, old.controller.class, 'Stare wejście nie używa rzeczywistego MatchEntry')
  F.button(form, 'Check status').press
  complete.call(old, form)
  assert_equal(:candidate, old.controller.reason)
  assert(!old.controller.view[:matches].empty?, 'Stare K03 nie osiągnęło prawdziwego kandydata')
  assert(F.field(form, 'Readiness and coordination').text.include?('No local test plan has been accepted'), 'FT1 zostało pomylone z planem K03')
  old_session = hub.instance_variable_get(:@readiness_session)
  old_identity = old_session.backend_events.snapshot[:value]
  connection = old.controller.instance_variable_get(:@readiness_connection)
  original = connection.method(:perform)
  connection.define_singleton_method(:perform) do |**options|
    old_entered << Thread.current
    old_release.pop
    original.call(**options)
  end
  F.button(form, 'Check status').press
  old_worker = Timeout.timeout(5) { old_entered.pop }
  old_work = old.instance_variable_get(:@readiness_work)
  old_view = old.controller.view
  F.button(form, 'Back').press
end
driver.step('Local tournament tests', [13]) do |form|
  assert_equal(nil, hub.instance_variable_get(:@match_entry))
  assert(old_work.closed?, 'K03 zachował aktywny Work po powrocie')
  assert_equal(nil, old.controller.instance_variable_get(:@readiness_connection))
  assert_equal(nil, old.controller.context.instance_variable_get(:@owner_reader))
  assert_equal([0, 0], [old_session.actor_events.listener_count, old_session.backend_events.listener_count])
  form.index = form.fields.index(F.button(form, 'Change test participant'))
end
F.actor(driver, 'Bartek')
driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(F.button(form, F::ACTION)) }
driver.step('Accepted fixed-team plans') do |form|
  current = hub.instance_variable_get(:@fixed_team_entry)
  F.button(form, 'Check status').press
  complete.call(current, form)
  assert_equal(T::LocalFixedTeamEntry, current.controller.class)
  current_session = current.controller.session
  assert(!current_session.equal?(old_session), 'FT2 pożyczyło lifecycle K03')
  assert(current_session.runtime_id != old_session.runtime_id, 'FT2 pożyczyło runtime_id K03')
  assert(current_session.backend_events.snapshot[:value] != old_identity, 'FT2 pożyczyło backend K03')
  assert_equal('bartek', current_session.actor_events.snapshot[:value])
  assert_equal('bartek', old_session.actor_events.snapshot[:value], 'Jawny wybór Huba nie zmienił jego własnej sesji')
  assert_equal('Bartek', hub.instance_variable_get(:@workspace).actor)
  assert_equal(F::OWNER.downcase, hub.instance_variable_get(:@workspace).entry_descriptor['owner'])
  assert_equal(fixture[:record], current.controller.view[:tournaments].first['record'])
  assert_equal('unknown', current.controller.view[:current]['state'])
  assert_equal([], current.controller.view[:records])
  saved = current.controller.view
  speech = [SpeechOutput.calls.size, NVDA.calls.size]
  old_release << true
  assert(old_worker.join(5), 'Stary worker K03 nie zakończył się')
  assert_equal(speech, [SpeechOutput.calls.size, NVDA.calls.size])
  assert(current.controller.view.equal?(saved) && old.controller.view.equal?(old_view), 'Spóźniony K03 podmienił widok')
  assert_equal(nil, old_work.take)
  assert_equal([nil, nil, nil], [:operation, :result, :handle].map { |name| old_work.instance_variable_get("@#{name}") })
  before = snapshot.call
  if mode != 'healthy'
    connection = current.controller.instance_variable_get(:@connection)
    original = connection.method(:perform)
    connection.define_singleton_method(:perform) do |**options|
      entered << Thread.current
      release.pop
      if mode == 'owner'
        user = 'InnyWlasciciel'
        hub.instance_variable_get(:@owner).current
        user = F::OWNER
      end
      original.call(**options)
    end
    F.button(form, 'Ready').press
    current_worker = Timeout.timeout(5) { entered.pop }
    current_work = current.instance_variable_get(:@readiness_work)
    case mode
    when 'actor_aba'
      current_session.choose_actor('Ala'); current_session.choose_actor('Bartek')
    when 'backend_aba'
      identity = current_session.backend_events.snapshot[:value]
      current_session.change_backend('local-test-k03:other'); current_session.change_backend(identity)
    when 'program' then program.finalize(reason: :error)
    when 'runtime' then Programs.unregister_runtime(runtime)
    end
    release << true
    assert(current_worker.join(5), 'Worker FT2 nie zakończył się')
    speech = [SpeechOutput.calls.size, NVDA.calls.size]
    form.update
    assert_equal(speech, [SpeechOutput.calls.size, NVDA.calls.size], 'Wygasłe FT2 zaprezentowało stary wynik')
  end
end
driver.step('Accepted fixed-team plans', [27]) if mode == 'healthy'
driver.step('Local tournament tests', [27]) do |_form|
  assert_equal(nil, hub.instance_variable_get(:@fixed_team_entry))
  assert_equal(nil, hub.instance_variable_get(:@match_entry))
end
begin
  hub.run
  driver.finish
  assert_equal(before, snapshot.call, 'Odczyt albo wygasły Ready zmienił trwałe pliki')
  assert_equal([0, 0], [program.managed_resources.size, runtime.managed_resources.size])
  [old_session, current_session].each do |session|
    assert_equal([0, 0], [session.actor_events.listener_count, session.backend_events.listener_count])
  end
  assert_equal(nil, current.controller.instance_variable_get(:@connection))
  assert_equal(nil, current.controller.context.instance_variable_get(:@owner_reader))
  work = current.instance_variable_get(:@readiness_work)
  assert(work.closed?, 'Zamknięty FT2 zatrzymał aktywne Work')
  assert_equal([nil, nil, nil], [:operation, :result, :handle].map { |name| work.instance_variable_get("@#{name}") })
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'c09.json'), JSON.pretty_generate({mode: mode, old_identity: old_identity,
    old_runtime: old_session.runtime_id, ft2_runtime: current_session.runtime_id, source_before: before, source_after: snapshot.call,
    old_worker_joined: !old_worker.alive?, new_worker_joined: !current_worker || !current_worker.alive?, registries: [0, 0], listeners: [0, 0], alerts: alerts}))
  puts "PASS C09 #{mode}: prawdziwy Hub/K03/powrót/jawny Bartek/FT2/powrót; osobne lifecycle/backend, spóźniony K03, cleanup i niezmienne pliki"
ensure
  old_release << true if old_worker&.alive?
  release << true if current_worker&.alive?
  old_worker&.join(5)
  current_worker&.join(5)
  program.finalize(reason: :error)
  Programs.unregister_runtime(runtime)
end
