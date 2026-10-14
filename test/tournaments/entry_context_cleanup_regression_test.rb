# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/match_entry_screen'
include GameRoomTest::Assertions
G = GameRoomTournaments
E = TournamentEntryContextTest
[false, true].product([false, true]).each do |with_cause, broken|
  cause = with_cause ? ArgumentError.new('Przyczyna pierwotna') : nil
  primary = NoMethodError.new('Błąd snapshot')
  primary.set_backtrace(['pierwotne.rb:17'])
  begin; raise primary, cause: cause; rescue NoMethodError; end
  trace = primary.backtrace.dup
  secondary = IOError.new('Błąd odpięcia')
  program = E::Program.new
  runtime = program.class.app_runtime
  source = E::Events.new('alice')
  captured = nil
  manage = program.method(:manage)
  program.define_singleton_method(:manage) { |context| captured = context; manage.call(context) }
  source.define_singleton_method(:snapshot) { raise primary, cause: cause }
  subscribe = source.method(:subscribe)
  source.define_singleton_method(:subscribe) do |&listener|
    handle = subscribe.call(&listener)
    close = handle.method(:close)
    handle.define_singleton_method(:close) { close.call; raise secondary if broken }
    handle
  end
  observed = begin
    begin; raise ArgumentError, 'Obcy obsłużony wyjątek'; rescue ArgumentError
      G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { 'Alice' }, account_events: source)
    end
  rescue Exception => error; error
  end
  assert(observed.equal?(primary), 'Cleanup zamaskował obiekt primary')
  assert(observed.cause.equal?(cause) && observed.backtrace == trace, 'Cleanup zmienił cause lub backtrace primary')
  assert(source.listeners.empty? && [program, runtime].all? { |owner| owner.managed_resources.size == 0 }, 'Niepełne zwolnienie')
  if broken
    receipt = captured.cleanup_attempts.last
    assert(receipt[:failures].first[:message] == secondary.message, 'Brak oddzielnego błędu cleanup')
    assert(receipt[:attempt_id] && receipt.frozen? && receipt[:failures].first.frozen?, 'Receipt nie jest odłączonym snapshotem próby')
    secondary.message.replace('Zmieniony obiekt wyjątku')
    captured.close
    assert(receipt[:failures].first[:message] == 'Błąd odpięcia', 'Zmiana wyjątku zmieniła dawny receipt')
  end
end
program = E::Program.new
context = G::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { 'Alice' })
secondary = IOError.new('Samodzielne close')
release = program.method(:release)
program.define_singleton_method(:release) { |value| release.call(value); raise secondary, cause: nil }
observed = begin
  begin; raise ArgumentError, 'Ambient'; rescue ArgumentError; context.close; end
rescue Exception => error; error
end
assert(observed.equal?(secondary) && observed.cause.nil?, 'Ambient rescue ukrył samodzielne close')
puts 'PASS 04: dokładny primary/cause/backtrace, odłączony receipt cleanup, samodzielne close'
