# encoding: UTF-8
require_relative '../support/fixed_team_budget_support'
include FixedTeamBudgetSupport
context, service, reference = fixture
with_backend(context) do |backend, _, _, _, directory|
  # To kontrola wspólnego walidatora JSON, NIE fikcyjna akceptacja planu.
  value = 'ż' + '"' * ((LIMIT - 4) / 2)
  assert_equal(LIMIT, JSON.generate(value).bytesize)
  assert_equal(value, backend.send(:detached, value))
  bytes_error = assert_raises(T::Publication::Invalid) { backend.send(:detached, value + 'r') }
  assert_equal(:json_budget, bytes_error.code)
  nodes = Array.new(65_535, nil)
  assert_equal(65_536, miary(nodes)['nodes'])
  assert_equal(nodes, backend.send(:detached, nodes))
  nodes_error = assert_raises(T::Publication::Invalid) { backend.send(:detached, nodes + [nil]) }
  assert_equal(:json_budget, nodes_error.code)
  depth = nil
  16.times { depth = [depth] }
  assert_equal(16, miary(depth)['depth'])
  assert_equal(depth, backend.send(:detached, depth))
  depth_error = assert_raises(T::Publication::Invalid) { backend.send(:detached, [depth]) }
  assert_equal(:json_budget, depth_error.code)
  shown, = podglad(context, service, backend, reference, 'glebokosc')
  record = backend.accept(preview: shown)
  oracle_file('oracle.json', {'scope' => 'Sam walidator JSON; brak accept syntetycznych struktur',
    'bytes_boundary' => miary(value), 'nodes_boundary' => miary(nodes), 'depth_boundary' => miary(depth),
    'errors' => [opis_bledu(bytes_error), opis_bledu(nodes_error), opis_bledu(depth_error)],
    'legal_record' => miary(record), 'source' => miary(shown['source']), 'evidence' => miary(record['evidence']),
    'depth_bound' => {'source_max' => 12, 'source_in_preview_record' => 14, 'evidence_max' => 12, 'evidence_in_record' => 13,
      'record_max' => 14, 'readback_max' => 16}})
end
puts 'FT1-R1: dokładne brzegi wspólnego walidatora bajtów, węzłów i głębokości — OK'
