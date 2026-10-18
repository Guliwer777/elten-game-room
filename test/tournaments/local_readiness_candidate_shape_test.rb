# encoding: UTF-8
require_relative '../support/tournament_local_readiness'

include TournamentLocalReadinessSupport
include GameRoomTest::Assertions

checks = 0
sandbox do |context|
  fixture = prepared(context)
  backend = fixture.fetch(:backend)
  path = backend.instance_variable_get(:@storage).path
  bytes = File.binread(path)
  expected = backend.plans
  candidate = fixture.fetch(:candidate)
  original_candidate = candidate.to_h
  cold = T::LocalReadinessBackend.new(directory: File.dirname(path), actor: 'Alicja',
    clock: -> { context.now }, source: fixture.fetch(:source))
  assert_equal(expected, cold.plans)
  assert_equal(fixture.fetch(:anchor), cold.accept(candidate: candidate))
  assert_equal(bytes, File.binread(path), 'Idempotent acceptance must not rewrite the local plan')

  paths = [[], ['publication_ref'], ['roster'], ['matches'], ['matches', 0], ['windows'], ['game_options']]
  begin
    paths.each do |keys|
      [nil, false, true, 0, 0.0, '', [], {}].each do |value|
        altered = JSON.parse(bytes)
        if keys.empty?
          altered['plans'].first['candidate'] = value
        else
          parent = keys[0...-1].inject(altered['plans'].first['candidate']) { |node, key| node.fetch(key) }
          parent[keys.last] = value
        end
        supplied = JSON.generate(altered)
        File.binwrite(path, supplied)
        refused = false
        begin
          cold.plans
        rescue T::ReadinessContract::Blocked => error
          assert_equal(:sandbox_corrupt, error.code, "Unexpected refusal for #{keys.inspect}: #{value.inspect}")
          refused = true
        ensure
          assert_equal(supplied.b, File.binread(path), 'Rejected readback must not normalize or rewrite the JSON')
        end
        assert(refused, "Malformed stored candidate was accepted: #{keys.inspect}: #{value.inspect}")
        checks += 1
      end
    end
  ensure
    File.binwrite(path, bytes)
  end

  assert_equal(expected, cold.plans)
  assert_equal(fixture.fetch(:anchor), cold.accept(candidate: candidate))
  assert_equal(original_candidate, candidate.to_h)
  assert_equal(bytes, File.binread(path), 'Restored valid plan must remain byte-identical')
end

puts "PASS local readiness candidate shapes: #{checks} typed refusals, unchanged JSON, valid cold and idempotent readback"
