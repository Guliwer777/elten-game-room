# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja konstrukcji U'); super(value, message); end
U = TournamentFT2B1UI
F = U::F
T = F::T
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
program = fixture[:program]
primary = NoMethodError.new('Błąd konstrukcji kontrolera po nabyciu kontekstu')
primary.set_backtrace(['konstrukcja_u.rb:9'])
cause = ArgumentError.new('Przyczyna konstrukcji')
secondary = Exception.new('Wtórny błąd release')
original_new = T::LocalFixedTeamEntry.method(:new)
original_release = program.method(:release)
session = context = nil
begin
  T::LocalFixedTeamEntry.define_singleton_method(:new) do |**options|
    session, context = options.values_at(:session, :context)
    raise primary, cause: cause
  end
  program.define_singleton_method(:release) do |resource|
    original_release.call(resource)
    raise secondary, cause: nil
  end
  owner = T::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(message) { raise message })
  workspace = T::LocalWorkspace.new(**F.args(fixture).reject { |k, _| k == :confirm }, actor: 'Ala')
  screen = T::LocalFixedTeamExecutionScreen.new(program: program, workspace: workspace, owner: owner)
  observed = nil
  begin
    screen.run
  rescue Exception => error
    observed = error
  end
  U.evidence('construction', {observed: [observed.class.name, observed.message, observed.backtrace], registry: [program.managed_resources.size, program.class.app_runtime.managed_resources.size], session_closed: session.closed?})
  assert(observed.equal?(primary), 'Wtórny cleanup zastąpił primary częściowej konstrukcji FT2')
  assert(observed.cause.equal?(cause))
  assert_equal(['konstrukcja_u.rb:9'], observed.backtrace)
  assert(session.closed?, 'Nie zamknięto sesji po błędzie cleanup kontekstu')
  assert_equal([0, 0], [program.managed_resources.size, program.class.app_runtime.managed_resources.size])
  assert_equal([0, 0], [session.actor_events.listener_count, session.backend_events.listener_count])
  assert_equal(nil, context.instance_variable_get(:@owner_reader))
  puts 'PASS częściowa konstrukcja FT2: primary/cause/backtrace, oba Registry, zamknięta sesja i zwolnione closure'
ensure
  T::LocalFixedTeamEntry.define_singleton_method(:new, original_new)
  program.define_singleton_method(:release, original_release)
  program.finalize; program.class.app_runtime.close
end
