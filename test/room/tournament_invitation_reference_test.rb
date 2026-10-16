# encoding: UTF-8
require_relative '../support/tournament_match_fix_cases'
fix = TournamentMatchFixCases

[2, 3].product([:join, :reconnect], [2, 3, 4], [:replace, :same_ids_copy, :id, :in_place]).each do |count, mode, read_number, mutation|
  fix.run("#{count} osoby #{mode} odczyt=#{read_number} zmiana=#{mutation}") do |row|
    scenario = TournamentMatchScenario.new(game_id: count == 2 ? 'uno' : 'three_five_eight', names: %w[Alice Bob Carol].take(count))
    other = fix.other_room(scenario)
    original_table, original_id = scenario.invitation.table, scenario.invitation.id
    released, established = [], []
    establish, release = scenario.membership.method(:establish), scenario.membership.method(:release)
    scenario.membership.define_singleton_method(:establish) do |**arguments|
      established << arguments.fetch(:table)
      establish.call(**arguments)
    end
    scenario.membership.define_singleton_method(:release) do |receipt|
      released << receipt
      release.call(receipt)
    end
    mutations = 0
    scenario.port.during_read = lambda do
      if scenario.port.calls.size == read_number
        mutations += 1
        case mutation
        when :replace then scenario.invitation.table = other
        when :same_ids_copy then scenario.invitation.table = original_table.dup
        when :id then scenario.invitation.invitation['__id'] = original_id + 1
        when :in_place then scenario.invitation.table['__live_session_id'] = other['__live_session_id']
        end
      end
    end
    result = mode == :join ? scenario.join : scenario.acceptance.reconnect(scenario.invitation, binding: scenario.binding, consent: scenario.consent)
    row['result'] = mode == :join ? result.result.to_s : result
    fix.state(scenario, row)
    row['mutations'] = mutations
    row['other_present'] = scenario.broker.cores.fetch(other['__live_session_id']).participants.key?('alice')
    assert(mutations == 1 && scenario.port.calls.size == read_number, 'Brak granicy albo dodatkowe I/O po odmowie')
    assert(mode == :join ? result.result == :target_changed && !result.left_current : result.equal?(false), 'Zmiana celu przyjęta')
    expected = read_number == 2 ? 0 : 1
    assert(scenario.membership.establish_count == expected && scenario.membership.release_count == expected, 'Skutek przed walidacją aktualnego celu')
    assert(scenario.calls[:leave] == 0 && scenario.calls[:complete] == 0 && scenario.calls[:reconnect] == 0, 'Dalszy skutek po podmianie')
    assert(scenario.old_present? && !row['other_present'] && !scenario.target_present?, 'Utrata starego stołu albo cudza membership')
    assert(established.all? { |table| table.equal?(original_table) }, 'Establish dostał inny descriptor')
    assert(released.all? { |receipt| receipt.eql?(scenario.membership.last_receipt) && receipt.frozen? && !receipt.equal?(scenario.membership.last_receipt) }, 'Cleanup nie własnego receipt')
    assert(!original_table.frozen? && !scenario.invitation.frozen? && !scenario.invitation.invitation.frozen?, 'Zamrożono cudzy nośnik')
  end
end

[2, 3].product([:join, :reconnect]).each do |count, mode|
  fix.run("Zgodny descriptor bez kopii/obcięcia: #{count} osoby #{mode}") do |row|
    scenario = TournamentMatchScenario.new(game_id: count == 2 ? 'uno' : 'three_five_eight', names: %w[Alice Bob Carol].take(count))
    scenario.alice.send(:leave_current_table, scenario.old) if mode == :reconnect
    descriptor = scenario.invitation.table
    # Obiekt niebędący JSON-em reprezentuje nieprzenoszalny uchwyt; nie kopiujemy go.
    marker = descriptor['fixture_handle'] = Object.new
    establish = scenario.membership.method(:establish)
    scenario.membership.define_singleton_method(:establish) do |**arguments|
      assert(arguments[:table].equal?(descriptor) && arguments[:table]['fixture_handle'].equal?(marker), 'Skopiowano/obcięto descriptor')
      establish.call(**arguments)
    end
    result = mode == :join ? scenario.join : scenario.acceptance.reconnect(scenario.invitation, binding: scenario.binding, consent: scenario.consent)
    assert(mode == :join ? result.result.entered? : result.equal?(true), 'Odmowa zgodnego wejścia')
    assert(scenario.membership.release_count == 0 && scenario.calls[:complete] == 1 && scenario.calls[:reconnect] == 0, 'Zmiana zwykłej ścieżki lub cleanup po sukcesie')
    assert(scenario.port.calls.size == (mode == :join ? 7 : 6), 'Dodano I/O do kontroli referencji')
    assert(!descriptor.frozen? && descriptor['fixture_handle'].equal?(marker), 'Zmieniono cudzy uchwyt')
    fix.state(scenario, row)
  end
end

[:table, :id].product([2, 3, 4]).each do |getter, read_number|
  fix.run("ProgramError gettera #{getter} po readback #{read_number}") do |row|
    scenario = TournamentMatchScenario.new
    original = fix.exception('Błąd gettera bieżącego zaproszenia')
    cause, trace = original.cause, original.backtrace.dup
    scenario.port.during_read = lambda do
      if scenario.port.calls.size == read_number
        scenario.invitation.define_singleton_method(getter) { raise original }
      end
    end
    caught = fix.caught { scenario.join }
    assert(caught.equal?(original) && caught.cause.equal?(cause) && caught.backtrace == trace, 'Zamaskowano getter ProgramError')
    assert(scenario.calls[:leave] == 0 && scenario.calls[:complete] == 0 && scenario.old_present?, 'Skutek po uszkodzonym getterze')
    assert(scenario.membership.establish_count == (read_number == 2 ? 0 : 1), 'Getter sprawdzony za późno')
    assert(scenario.membership.release_count == (read_number == 2 ? 0 : 1), 'Nie sprzątnięto własnego receipt po getterze')
    fix.state(scenario, row)
  end
end

fix.run('Podmiana referencji nie uprawnia cleanup zastąpionej generacji') do |row|
  scenario = TournamentMatchScenario.new
  other = fix.other_room(scenario)
  scenario.port.during_read = lambda do
    if scenario.port.calls.size == 3
      core = scenario.broker.cores.fetch(scenario.target['__live_session_id'])
      core.participants['alice'] = NativeLiveSessionsBroker::Participant.new(id: 'nowa-generacja', user: 'Alice')
      scenario.invitation.table = other
    end
  end
  result = scenario.join
  assert(result.result == :target_changed && scenario.calls[:leave] == 0 && scenario.calls[:complete] == 0, 'Skutek po zmianie')
  assert(scenario.old_present? && scenario.target_present? && scenario.membership.release_count == 1, 'Cleanup usunął cudzą generację')
  fix.state(scenario, row)
end
fix.finish
