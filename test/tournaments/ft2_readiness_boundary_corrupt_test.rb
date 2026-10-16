# encoding: UTF-8
require_relative '../support/ft2_readiness_boundary_support'
B = FT2ReadinessBoundarySupport
F = B::F
J = B::J
directory, port, context, declared = B.prepare
healthy_map = B.map(directory)
state_path = Dir.glob(File.join(directory, '**', 'state.json')).fetch(0)
intent_path = Dir.glob(File.join(directory, '**', '*.intent')).fetch(0)
observed_path = Dir.glob(File.join(directory, '**', '*.observed')).fetch(0)
healthy = [state_path, intent_path, observed_path].to_h { |path| [path, File.binread(path)] }
operation = JSON.parse(healthy[intent_path])
generic = 'Uszkodzony dziennik gotowości'
mutate_json = ->(path, &change) { data = JSON.parse(healthy.fetch(path)); change.call(data); JSON.generate(data) }
cases = [
  ['state: uszkodzony JSON', state_path, '{', generic, 'JSON::ParserError'],
  ['state: błędny UTF-8', state_path, "\xff".b, 'Błędny UTF-8', nil],
  ['state: parsowalny błędny schemat', state_path, '{}', generic, 'GameRoomTournaments::Publication::Invalid'],
  ['state: wersja', state_path, mutate_json.call(state_path) { |d| d['version'] = 2 }, 'Niezgodny dziennik', nil],
  ['intent: uszkodzony JSON', intent_path, '{', generic, 'JSON::ParserError'],
  ['intent: schemat', intent_path, '{}', generic, 'GameRoomTournaments::Publication::Invalid'],
  ['intent: digest', intent_path, mutate_json.call(intent_path) { |d| d['request_digest'] = '0' * 64 }, generic, 'GameRoomTournaments::Publication::Invalid'],
  ['intent: domenowa odmowa', intent_path, mutate_json.call(intent_path) { |d| d['accepted_match']['full_roster'] = false }, generic, 'GameRoomTournaments::ReadinessContract::Blocked'],
  ['observed: uszkodzony JSON', observed_path, '{', generic, 'JSON::ParserError'],
  ['observed: schemat', observed_path, '{}', generic, 'GameRoomTournaments::Publication::Invalid'],
  ['observed: nieterminalny', observed_path, mutate_json.call(observed_path) { |d| d['status'] = 'pending'; d['result'] = nil }, 'Nieterminalna obserwacja', nil],
  ['observed: sprzeczne legalne dowody', observed_path, mutate_json.call(observed_path) { |d| d['result']['server_time'] += 1 }, 'Sprzeczne dowody końcowe', nil],
  ['terminal: brak dowodu', state_path, mutate_json.call(state_path) { |d| d['records'][0]['evidence'] = nil }, generic, 'GameRoomTournaments::ReadinessContract::PortUnavailable'],
  ['terminal: dowód tablica', state_path, mutate_json.call(state_path) { |d| d['records'][0]['evidence'] = [] }, generic, 'GameRoomTournaments::Publication::Invalid'],
  ['terminal: obcy digest', state_path, mutate_json.call(state_path) { |d| d['records'][0]['evidence']['request_digest'] = '0' * 64 }, generic, 'GameRoomTournaments::ReadinessContract::Blocked'],
  ['terminal: inny status', state_path, mutate_json.call(state_path) { |d| d['records'][0]['evidence']['status'] = 'refused'; d['records'][0]['evidence']['result'] = nil }, 'Błędny dowód końcowy', nil],
  ['prepared: obcy dowód', state_path, mutate_json.call(state_path) { |d| d['records'][0]['status'] = 'prepared' }, 'Niepoprawny dowód próby', nil]
]
rows = []
at_exit { B.persist('corrupt-controls.json', {healthy_declaration: declared, healthy_bytes_hex: healthy.transform_values { |bytes| bytes.unpack1('H*') }, rows: rows}) }
cases.each do |name, path, bytes, message, cause_class|
  if name == 'observed: sprzeczne legalne dowody'
    B::C.response!(JSON.parse(bytes), operation)
    B::C.response!(JSON.parse(healthy[observed_path]), operation)
  end
  File.binwrite(path, bytes)
  before = B.map(directory)
  calls = port.calls.dup
  writes = []; visits = []; error = nil; result = nil
  trace = TracePoint.new(:call, :c_return) do |event|
    if event.event == :call && event.defined_class == J
      visits << event.method_id
      writes << event.method_id if %i[claim observe resolve write_file write_state].include?(event.method_id)
    end
  end
  service = F.service(directory, port, context)
  begin
    trace.enable(target_thread: nil)
    store = B.journal(directory, ->(cleanup: false, &block) { block.call })
    begin
      store.with_attempt { store.records }
    rescue J::Corrupt => caught
      error = caught
    end
    result = service.reconcile(scope: F.scope, match_ref: F.match_ref, operation_id: declared[:operation_id])
  ensure
    trace.disable
  end
  rows << {case: name, mutation_path: path, mutation_bytes_hex: bytes.b.unpack1('H*'),
    expected_message: message, expected_cause_class: cause_class,
    actual_error: error && {class: error.class.name, message: error.message, cause: error.cause&.class&.name, operation: error.operation},
    result: result, diagnostics: service.diagnostics, visits: visits, mutations: writes,
    port_calls: port.calls.drop(calls.size), before: before, after: B.map(directory), locks: B.locks(directory)}
  F.assert(error && error.message == message && error.cause&.class&.name == cause_class, "Właściwy Corrupt i przyczyna: #{name}")
  F.assert(result[:state] == :blocked && result[:reason] == :journal_corrupt, "Właściwa odmowa Service: #{name}")
  F.assert(rows.last[:after] == before && writes.empty? && rows.last[:locks].values.all?, "Brak mutacji i zwolniony lock: #{name}")
  F.assert(rows.last[:port_calls] == [:negotiate], 'Odmowa przed store i lookup')
  File.binwrite(path, healthy.fetch(path))
  recovered = F.service(directory, port, context).reconcile(scope: F.scope, match_ref: F.match_ref, operation_id: declared[:operation_id])
  F.assert(recovered == declared && B.map(directory) == healthy_map, 'Przywrócone zdrowe bajty rzeczywiście przechodzą bez nowego zapisu')
end
puts JSON.generate({passed: rows.size, opis: 'Rzeczywiste uszkodzenia JSON/UTF-8/schema/intent/observed/terminal nadal jawnie odmawiają'})
