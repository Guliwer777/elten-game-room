# encoding: UTF-8
require_relative '../support/fixed_team_budget_support'
include FixedTeamBudgetSupport
context, service, reference = fixture
with_backend(context) do |backend, build, _, _, directory|
  small, input = podglad(context, service, backend, reference, 'granica')
  small_record = backend.send(:compile, small)
  overhead = JSON.generate(small_record).bytesize - JSON.generate(small).bytesize
  shown, additions = powieksz(context, backend, input, small, LIMIT - overhead - 256)
  record = backend.accept(preview: shown)
  measures = miary(record)
  assert(measures['bytes'].between?(LIMIT - 260, LIMIT), 'Cały rekord tuż pod granicą 1 MiB')
  assert(measures['nodes'] <= 65_536 && measures['depth'] <= 16)
  assert(additions.any? { |row| row['rules_json_bytes'] > row['rules_bytes'] + 2 }, 'Escapowanie jest rzeczywiste, nie sam ASCII')
  assert(shown['source']['announcements'].any? { |row| row['rules'].include?("ż\"\\\n\t") }, 'UTF-8 oraz znaki escapowane')
  before = zapisane_pliki(directory)
  error, calls = bez_zapisu do
    assert_equal(record, build.call.readback(intent_id: 'granica'))
    assert_equal(record, build.call.current(intent_id: 'granica'))
    assert_equal(record, build.call.accept(preview: shown))
  end
  assert_equal(nil, error)
  assert_equal([], calls)
  assert_equal(before, zapisane_pliki(directory))
  alias_shown = backend.preview(**input.merge(intent_id: 'alias-granicy'))
  assert_equal(record, backend.accept(preview: alias_shown))
  after_alias = zapisane_pliki(directory)
  recovered = build.call.readback(intent_id: 'alias-granicy')
  assert_equal(record, recovered)
  zamrozony(recovered)
  assert_equal(after_alias, zapisane_pliki(directory))
  payloads = dokladne_payloady(recovered)
  oracle_file('oracle.json', {'record' => record, 'measures' => measures, 'shown_measures' => miary(shown),
    'overhead' => overhead, 'additions' => additions, 'alias' => alias_shown, 'before' => before,
    'after_alias' => after_alias, 'payloads' => payloads, 'retry_calls' => calls})
end
puts 'FT1-R1: bliska granica całego JSON UTF-8, readback, retry i alias — OK'
