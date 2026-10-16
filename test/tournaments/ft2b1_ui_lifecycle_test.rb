# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja lifecycle U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
fixture[:program].finalize; fixture[:program].class.app_runtime.close
module Log
  def self.debug(_message); end
  def self.warning(_message); end
  def self.info(_message); end
end
require EltenTestHost.file('src/eapi/program.rb')
results = []
[:actor_aba, :backend_aba, :program, :runtime, :back].each do |mode|
  manifest = Struct.new(:id, :namespace_name, :execution).new('19d0c035-2e6d-4528-bfd9-f5ac2542dfe1', 'UProbe', Programs::Execution::Spec.new({'backend' => 'runtime'}))
  runtime = Programs::Runtime.new(entry_id: "u-#{mode}", root: ENV.fetch('FT2_SCRATCH'), manifest: manifest)
  klass = Programs.with_runtime(runtime) { Class.new(::Program) }
  klass.instance_variable_set(:@app_runtime, runtime)
  program = klass.new
  program.define_singleton_method(:data_path) { File.dirname(fixture[:sandbox]) }
  owner = T::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(message) { raise message })
  workspace = T::LocalWorkspace.new(program: program, registry: F::REGISTRY, user: owner.method(:current), actor: 'Ala', alert: ->(message) { raise message }, clock: -> { fixture[:now] })
  screen = T::LocalFixedTeamExecutionScreen.new(program: program, workspace: workspace, owner: owner)
  driver = TournamentNativeDriver.new
  session = worker = work = nil
  entered, release = Queue.new, Queue.new
  before = U.snapshot(fixture[:sandbox])
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press
    # Loading the persisted plan is not the lifecycle boundary under test.
    # Allow the same bounded settling time as the other native UI scenarios.
    2.times { work = screen.instance_variable_get(:@readiness_work); wait_background_work(work, timeout: 30) if work&.busy?; form.update }
    controller = screen.controller
    session = controller.session
    connection = controller.instance_variable_get(:@connection)
    original = connection.method(:perform)
    connection.define_singleton_method(:perform) do |**options|
      entered << Thread.current
      release.pop
      original.call(**options)
    end
    F.button(form, 'Ready').press
    worker = Timeout.timeout(5) { entered.pop }
    assert(worker != Thread.current)
    case mode
    when :actor_aba
      session.choose_actor('Bartek'); session.choose_actor('Ala')
    when :backend_aba
      initial = session.backend_events.snapshot[:value]
      session.change_backend('local-test-u:other'); session.change_backend(initial)
    when :program then program.finalize(reason: :error)
    when :runtime then Programs.unregister_runtime(runtime)
    when :back then F.button(form, 'Back').press
    end
    form.update unless mode == :back
    speech = [SpeechOutput.calls.size, NVDA.calls.size]
    release << true
    assert(worker.join(5), 'Spóźniony worker nie zakończył się')
    assert_equal(speech, [SpeechOutput.calls.size, NVDA.calls.size], 'Spóźniona prezentacja')
  end
  begin
    screen.run; driver.finish
    assert_equal(before, U.snapshot(fixture[:sandbox]), 'Stary worker zapisał dane')
    assert_equal([0, 0], [program.managed_resources.size, runtime.managed_resources.size])
    assert_equal([0, 0], [session.actor_events.listener_count, session.backend_events.listener_count])
    assert_equal(nil, screen.controller.instance_variable_get(:@connection))
    assert_equal(nil, screen.controller.context.instance_variable_get(:@owner_reader))
    assert(work.closed?, 'Work zachował closure')
    results << {mode: mode, worker_joined: !worker.alive?, registry: [0, 0], listeners: [0, 0], source: before}
  ensure
    release << true if worker&.alive?
    worker&.join(5)
    program.finalize(reason: :error)
    Programs.unregister_runtime(runtime)
  end
end
U.evidence('lifecycle', results)
puts 'PASS emitowane actor/backend ABA, rzeczywiste Program.finalize/Runtime.unregister, Back, spóźniony Work i cleanup'
