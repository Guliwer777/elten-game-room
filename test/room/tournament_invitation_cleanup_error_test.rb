# encoding: UTF-8
require_relative '../support/tournament_match_fix_cases'
fix = TournamentMatchFixCases

# Każda kombinacja sprawdza dokładny wyjątek, nie tylko klasę/tekst.
[1, 2, 3].product([:released, :unknown, :timeout]).each do |read_number, cleanup|
  fix.run("ProgramError odczyt=#{read_number} cleanup=#{cleanup}") do |row|
    scenario = TournamentMatchScenario.new
    original = fix.exception('Pierwotny błąd readback')
    cause, trace = original.cause, original.backtrace.dup
    secondary = fix.exception('Timeout cleanup', Timeout::Error)
    scenario.port.during_read = -> { raise original if scenario.port.calls.size == read_number }
    if cleanup == :timeout
      scenario.membership.define_singleton_method(:release) do |_receipt|
        @release_count += 1
        raise secondary
      end
    elsif cleanup == :unknown
      scenario.membership.release_result = :unknown
    end
    caught = fix.caught { scenario.join }
    row.merge!('same_exception' => caught.equal?(original), 'same_cause' => caught&.cause.equal?(cause),
      'same_backtrace' => caught&.backtrace == trace, 'caught_class' => caught&.class&.name)
    fix.state(scenario, row)
    assert(row.values_at('same_exception', 'same_cause', 'same_backtrace').all?, 'Cleanup zastąpił dokładny ProgramError/cause/backtrace')
    assert(scenario.old_present? && scenario.calls[:leave] == 0 && scenario.calls[:complete] == 0, 'Skutek po błędzie')
    after_establish = read_number == 3
    assert(scenario.membership.release_count == (after_establish ? 1 : 0), 'Nieprawidłowa własność cleanup')
    failures = scenario.acceptance.cleanup_failures
    if after_establish && cleanup != :released
      assert(failures.size == 1 && failures.frozen?, 'Brak jawnej wtórnej diagnostyki')
      failure = failures.first
      assert(failure.frozen? && failure.primary_error.equal?(original), 'Diagnostyka nie należy do tej operacji')
      assert(failure.receipt.eql?(scenario.membership.last_receipt) && !failure.receipt.equal?(scenario.membership.last_receipt), 'Diagnostyka nie ma własnego detached receipt')
      assert(failure.receipt.frozen?, 'Mutowalny receipt diagnostyki')
      if cleanup == :timeout
        assert(failure.cleanup_error.equal?(secondary) && failure.cleanup_error.cause.equal?(secondary.cause), 'Zgubiony wtórny Timeout')
      else
        assert(failure.cleanup_error.is_a?(GameRoomUseCases::AcceptInvitation::CleanupUnconfirmed), 'Zgubiony unknown')
      end
      assert(scenario.target_present?, 'Niepewna membership zniknęła zamiast pozostać do reconcile')
      row['secondary_class'] = failure.cleanup_error.class.name
    else
      assert(failures.empty?, 'Stara lub pozorna diagnostyka cleanup')
      assert(!scenario.target_present?, 'Nie oczyszczono własnej membership')
    end
  end
end

[:unknown, :timeout, :program_error].product([false, true]).each do |cleanup, inherited|
  fix.run("Bez własnego primary cleanup=#{cleanup} wywołanie_z_rescue=#{inherited}") do |row|
    scenario = TournamentMatchScenario.new
    scenario.port.during_read = -> { scenario.context['epoch'] += 1 if scenario.port.calls.size == 3 }
    secondary = fix.exception('Błąd samego cleanup', cleanup == :timeout ? Timeout::Error : fix::ProgramError)
    if cleanup == :unknown
      scenario.membership.release_result = :unknown
    else
      scenario.membership.define_singleton_method(:release) do |_receipt|
        @release_count += 1
        raise secondary
      end
    end
    operation = -> { scenario.join }
    caught = fix.caught do
      if inherited
        begin
          raise fix.exception('Obsłużony błąd wywołującego')
        rescue fix::ProgramError
          operation.call
        end
      else
        operation.call
      end
    end
    assert(caught, 'Cleanup został połknięty bez własnego pierwotnego błędu')
    if cleanup == :unknown
      assert(caught.is_a?(GameRoomUseCases::AcceptInvitation::CleanupUnconfirmed), 'Unknown nie zgłoszony')
    else
      assert(caught.equal?(secondary), 'Zamaskowano nowy wyjątek cleanup')
    end
    failure = scenario.acceptance.cleanup_failures.fetch(0)
    assert(failure.primary_error.nil? && failure.cleanup_error.equal?(caught), 'Odziedziczony $! udaje własny primary')
    assert(scenario.old_present? && scenario.target_present? && scenario.calls[:leave] == 0 && scenario.calls[:complete] == 0, 'Skutek mimo odmowy')
    fix.state(scenario, row)
    row['caught_class'] = caught.class.name
  end
end

fix.run('Already_here zachowuje primary i nie sprząta cudzej membership') do |row|
  scenario = TournamentMatchScenario.new
  scenario.alice.send(:establish_invited_table_transport, scenario.invitation.table)
  original = fix.exception('Błąd po already_here')
  trace, cause = original.backtrace.dup, original.cause
  scenario.port.during_read = -> { raise original if scenario.port.calls.size == 3 }
  scenario.membership.release_result = :unknown
  caught = fix.caught { scenario.join }
  assert(caught.equal?(original) && caught.cause.equal?(cause) && caught.backtrace == trace, 'Zmieniono błąd already_here')
  assert(scenario.membership.release_count == 0 && scenario.acceptance.cleanup_failures.empty?, 'Cleanup already_here')
  assert(scenario.old_present? && scenario.target_present?, 'Utrata starej membership')
  fix.state(scenario, row)
end

fix.run('Dwie próby tej samej instancji: osobne receipt, bez starego wyniku') do |row|
  scenario = TournamentMatchScenario.new
  original = fix.exception('Ten sam obiekt błędu w dwóch próbach')
  scenario.port.during_read = -> { raise original if [3, 6].include?(scenario.port.calls.size) }
  scenario.membership.release_result = :unknown
  2.times do
    assert(fix.caught { scenario.join }.equal?(original), 'Zmiana primary kolejnej próby')
    # Wyłącznie fixture usuwa niepewną membership przed odrębną próbą.
    scenario.alice.transport.deactivate_table(table_id: scenario.target['__id'])
  end
  failures = scenario.acceptance.cleanup_failures
  assert(failures.size == 2 && failures.map { |entry| entry.receipt['attempt_id'] }.uniq.size == 2, 'Diagnostyka nie ma własności konkretnej próby')
  scenario.port.during_read = nil
  scenario.membership.release_result = nil
  assert(scenario.join.result.entered?, 'Dodatnia kontrola kolejnego wejścia')
  assert(scenario.acceptance.cleanup_failures == failures, 'Sukces został przedstawiony jako kolejny stary błąd cleanup')
  assert(TournamentMatchScenario.new.acceptance.cleanup_failures.empty?, 'Globalny mutable latch między instancjami')
  fix.state(scenario, row)
end
fix.finish
