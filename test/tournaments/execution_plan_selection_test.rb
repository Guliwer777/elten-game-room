# encoding: UTF-8
require_relative '../support/tournament_execution_plan'
E = TournamentExecutionPlanFixture
F = TournamentCoordinationFixture
T = GameRoomTournaments
R = TournamentMatchFixture.registry

# Dwa legalne cele: callback zmienia tylko zwykłe String wywołującego.
evidence = E.evidence
evidence['source']['windows'] << E.copy(evidence['source']['windows'].first).merge('id'=>'window-2','opens'=>201,'closes'=>300)
evidence['source']['matches'].first['window_ids'] << 'window-2'
evidence['plan']['matches'].first['windows'] << E.copy(evidence['source']['windows'].last)
evidence['source']['matches'] << E.copy(evidence['source']['matches'].first).merge('match_id'=>'match-2')
evidence['plan']['matches'] << E.copy(evidence['plan']['matches'].first).merge('match_id'=>'match-2','execution_generation'=>'execution-2')
evidence['seal']['source_digest']=E.digest(evidence['source'])
evidence['plan']['source_digest']=evidence['seal']['source_digest']
evidence['plan_digest']=E.digest(evidence.slice('scope','plan'))
anchor = E.anchor(evidence)
original_evidence = E.copy(evidence)
original_anchor = E.copy(anchor)
failures = []
checks = 0
check = lambda do |name, &test|
  checks += 1
  begin
    test.call
    puts "PASS #{name}"
  rescue StandardError => error
    failures << [name, error]
    warn "FAIL #{name}: #{error.class}: #{error.message}"
  end
end

[:match_id, :window_id].each do |mode|
  check.call("pierwotny selektor #{mode}") do
    match_id = String.new('match-1')
    window_id = String.new('window-1')
    expected = T::CoordinationRequest.build(E.expected(evidence), registry: R).to_h
    calls = 0
    registry = Object.new
    registry.define_singleton_method(:build) do |id|
      calls += 1
      if calls == 1
        mode == :match_id ? match_id.replace('match-2') : window_id.replace('window-2')
      end
      R.build(id)
    end
    actual = E.request(evidence, expected_source: anchor, match_id: match_id, window_id: window_id, registry: registry)
    F.assert(calls.positive?, 'Nie osiągnięto callbacka katalogu')
    F.assert(match_id.eql?(mode == :match_id ? 'match-2' : 'match-1') &&
      window_id.eql?(mode == :window_id ? 'window-2' : 'window-1'), 'Callback nie zmienił caller')
    F.assert(!match_id.frozen? && !window_id.frozen?, 'Zamrożono selektor caller')
    F.assert(actual.to_h.eql?(expected), 'Zwrócono inny legalny request zamiast pierwotnego')
    F.assert(E.frozen_tree?(actual.to_h), 'Wynik nie jest deep-frozen')
    F.assert(evidence.eql?(original_evidence) && anchor.eql?(original_anchor), 'Zmieniono plan lub kotwicę')
  end
end

check.call('jawny match-2/leg=2/window-2') do
  other = E.copy(evidence)
  other['source']['matches'].last['leg'] = 2
  other['plan']['matches'].last['leg'] = 2
  other['seal']['source_digest'] = E.digest(other['source'])
  other['plan']['source_digest'] = other['seal']['source_digest']
  other['plan_digest'] = E.digest(other.slice('scope','plan'))
  match = other['plan']['matches'].last
  expected = T::CoordinationRequest.build(T::ExecutionPlanContract.payload(other, match, match['windows'].last), registry: R)
  actual = E.request(other, match_id: 'match-2', leg: 2, window_id: 'window-2')
  F.assert(actual.to_h.eql?(expected.to_h), 'Zmieniono jawny niedomyślny wybór')
end

# Bez pomocniczego copy: surowe złe typy trafiają do publicznej fabryki.
no_conversion = Object.new
no_conversion.define_singleton_method(:to_s) { raise 'Niedozwolona konwersja selektora' }
invalid_texts = [nil, 1, 1.0, :symbol, true, [], {}, no_conversion, '', ' ', "a\n", 'a'*257,
  'ą'*129, "\xFF".force_encoding('UTF-8'), "\xFF".b]
cases = [:match_id, :window_id].flat_map { |key| invalid_texts.map { |value| [key, value, :invalid_text] } }
cases += [nil, 1.0, '1', :symbol, true, 0, -1, T::Publication::MAX_INTEGER + 1, no_conversion].map { |value| [:leg, value, :invalid_leg] }
cases.each_with_index do |(key, value, code), index|
  check.call("typ i odmowa przed registry #{key}/#{index}") do
    calls = 0
    registry = Object.new
    registry.define_singleton_method(:build) { |id| calls += 1; R.build(id) }
    E.reject(code) do
      T::CoordinationRequest.from_execution_plan(**{evidence: evidence, expected_source: anchor,
        match_id: 'match-1', leg: 1, window_id: 'window-1', registry: registry}.merge(key => value))
    end
    F.assert(calls.zero?, 'Niepoprawny selektor dotarł do registry')
    F.assert(!value.frozen?, 'Fabryka zamroziła caller') if value.is_a?(String)
  end
end

[nil, RuntimeError.new('przyczyna zależności')].each_with_index do |cause, index|
  check.call("pierwotny błąd callbacka #{index}") do
    primary = RuntimeError.new('błąd katalogu')
    backtrace = ['testowy_katalog.rb:17:in build']
    primary.set_backtrace(backtrace)
    registry = Object.new
    calls = 0
    registry.define_singleton_method(:build) { |_id| calls += 1; raise primary, cause: cause }
    caught = nil
    begin
      E.request(evidence, expected_source: anchor, registry: registry)
    rescue StandardError => error
      caught = error
    end
    F.assert(calls == 1 && caught.equal?(primary), 'Zamaskowano obiekt błędu zależności')
    F.assert(caught.cause.equal?(cause) && caught.backtrace.eql?(backtrace), 'Zmieniono cause/backtrace')
  end
end
raise "Regresja selekcji: #{failures.map(&:first).join(', ')}" unless failures.empty?
puts "PASS selekcja: #{checks} przypadków; bez odmowy/FrozenError zamiast pierwotnego requestu"
