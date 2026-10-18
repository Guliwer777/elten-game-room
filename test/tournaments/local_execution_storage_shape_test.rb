require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

checks = 0
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'admission-shape-prestart'))
  people = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
  people.each do |actor|
    with_individual_execution(fixture, record, actor) do |execution|
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  with_individual_execution(fixture, record, people.first) do |execution|
    assert_equal(:bound, execution.request_match[:state])
    baseline = execution.progress
    path = execution.instance_variable_get(:@storage).path
    bytes = File.binread(path)
    key = JSON.parse(bytes).fetch('executions').keys.first
    [[false, nil], [true, nil], *[false, true, 0, 0.0, '', [], {}].map { |value| [true, value] }].each do |present, value|
      changed = JSON.parse(bytes)
      saved = changed.fetch('executions').fetch(key)
      present ? saved['admission'] = value : saved.delete('admission')
      altered = JSON.generate(changed)
      begin
        File.binwrite(path, altered)
        if value.nil?
          assert_equal(baseline, execution.progress, 'Absent or nil admission still means no entries')
        else
          refused = false
          begin
            execution.progress
          rescue T::Publication::Invalid => error
            assert_equal(:invalid_fields, error.code)
            refused = true
          end
          assert(refused, "Malformed admission was accepted: #{value.inspect}")
          checks += 1
        end
        assert_equal(altered.b, File.binread(path), 'Cold admission reads must not rewrite the file')
      ensure
        File.binwrite(path, bytes)
      end
    end
    assert_equal(baseline, execution.progress, 'Valid progress changed after restoring admission')
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: record.dig('preview', 'intent_id')))
  end
end

with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  # Actual local target, admission and Start, using the SDK/broker fixture.
  # Mutations below affect only this test's disposable JSON file, not a server.
  record = start_individual_match(fixture, intent_id: 'storage-shape-boundary')
  owner = record.dig('evidence', 'plan', 'matches').first.fetch('players').first.fetch('username')
  with_individual_execution(fixture, record, owner) do |execution|
    baseline = execution.progress
    path = execution.instance_variable_get(:@storage).path
    bytes = File.binread(path)
    document = JSON.parse(bytes)
    key = document.fetch('executions').keys.first
    paths = [['native', 'cores', 0], ['native', 'cores', 0, 'participants'],
      ['native', 'cores', 0, 'entries'], ['native', 'cores', 0, 'stack_entry_bytes'], ['executions', key, 'result']]
    paths.each do |keys|
      [nil, true, false, 0, 0.0, '', [], {}].each do |value|
        changed = JSON.parse(bytes)
        target = keys[0...-1].inject(changed) { |node, part| node.fetch(part) }
        target[keys.last] = value
        malformed = JSON.generate(changed)
        begin
          File.binwrite(path, malformed)
          refused = false
          begin
            execution.progress
          rescue T::Publication::Invalid, T::CoordinationContract::Blocked, T::ReadinessContract::Blocked => error
            assert(error.code.is_a?(Symbol), 'A damaged local record needs a typed refusal')
            refused = true
          end
          assert(refused, "Malformed local state was accepted: #{keys.inspect} = #{value.inspect}")
          assert_equal(malformed.b, File.binread(path), 'A rejected cold read must not rewrite the file')
        ensure
          File.binwrite(path, bytes)
        end
        checks += 1
      end
    end
    assert_equal(bytes, File.binread(path))
    assert_equal(baseline, execution.progress, 'Valid local progress changed after the damaged copies were removed')
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: record.dig('preview', 'intent_id')))
  end
end
puts "PASS local execution storage: #{checks} typed cold-read refusals, actual admission/Start retained, no rewritten bytes"
