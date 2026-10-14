# encoding: UTF-8
require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
include TournamentLocalExecutionPlanSupport
before = JSON.parse(File.read(File.join(ENV.fetch('FT1_SCRATCH'), 'shared', 'compat', 'before.json'), encoding: 'UTF-8'))
assert(before['pid'] != Process.pid)
values = before['results'].map do |row|
  path = row['path']
  bytes = File.binread(path)
  assert_equal(row['sha256'], Digest::SHA256.hexdigest(bytes))
  f = TournamentLocalExecutionPlanSupport::Fixture.new(File.dirname(File.dirname(path)), reopen: true)
  begin
    backend = f.backend
    assert_equal(row['source'], f.author_service.execution_source(publication_ref: f.reference), 'Pełne source v1 i wszystkie ID pozostają identyczne')
    record = backend.readback(intent_id: 'historyczny')
    assert_equal(row['record'], record)
    assert_equal(row['requests'], record['evidence']['plan']['matches'].map { |match| request(record, match) })
    assert_equal(record, backend.current(intent_id: 'historyczny'))
    assert_equal(record, backend.accept(preview: record['preview']))
    assert_equal(bytes, File.binread(path), 'Brak migracji lub przepisania choćby bajtu')
    changed = JSON.parse(JSON.generate(record['evidence']))
    changed['source']['source_kind'] = 'fixed-teams'
    error = assert_raises(T::Publication::Invalid) { T::ExecutionPlanContract.validate(changed, record['expected_source'], registry: GameRoomGames::CATALOG) }
    assert_equal(:invalid_fields, error.code)
    row.merge('readback' => record, 'extra_v2_field_rejected' => error.code, 'unchanged' => true)
  ensure
    f.close
  end
end
File.open(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'oracle.json'), 'wx:UTF-8') { |file| file.write(JSON.pretty_generate(values)) }
puts 'FT1: zimny odczyt prawdziwych v1 bez migracji, pełna zgodność źródła/requestów — OK'
