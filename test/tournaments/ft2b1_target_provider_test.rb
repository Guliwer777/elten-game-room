# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
record = fixture[:record]
begin
  # Każde wywołanie tworzy odrębny świadomie wybrany kontekst uczestnika.
  ['Ala', 'Anna', 'Bartek', 'Beata'].each do |actor|
    F.with_execution(fixture, actor) do |execution|
      F.select_execution(execution, record)
      result = execution.declare(availability: 'ready', expected_revision: 0)
      assert_equal(:confirmed, result[:state])
    end
  end
  deadline = record['evidence']['plan']['matches'].first['windows'].first['closes'] - 60
  F.with_execution(fixture, 'Ala', expires_at: deadline) do |execution|
    F.select_execution(execution, record)
    result = execution.request_match
    assert_equal(:bound, result[:state], "Produkcja nie tworzy exact celu: #{result.inspect}")
    target = result.fetch(:target).to_h
    assert_equal('private', target['readback']['visibility'])
    assert_equal(1, target['readback']['participants'].size)
    assert_equal('room_created', target['readback']['stack'].first['packet']['kind'])
    assert_equal(nil, target['readback']['game_instance'])
    assert_equal(target, execution.reconcile.fetch(:target).to_h)
    File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'target.json'), JSON.pretty_generate(target))
  end
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  puts 'PASS produkcyjny provider → realne Transport/Store → exact private target, jeden twórca, reconcile'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
