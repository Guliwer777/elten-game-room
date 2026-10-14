# encoding: UTF-8
require_relative 'tournament_ft2b1_execution'
module TournamentMovesFixture
  F = TournamentFT2B1
  module_function
  def build(game_options: {}, game_id: 'spades', registry: F::REGISTRY)
    fixture = F.fixture(Dir.mktmpdir('m', File.expand_path('../../tmp', __dir__)), game_options: game_options, game_id: game_id, registry: registry)
    record = fixture[:record]
    %w[Ala Anna Bartek Beata].each do |actor|
      F.with_execution(fixture, actor) do |execution|
        F.select_execution(execution, record)
        F.assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
      end
    end
    deadline = record['evidence']['plan']['matches'].first['windows'].first['closes'] - 60
    F.with_execution(fixture, 'Ala', expires_at: deadline) do |execution|
      F.select_execution(execution, record)
      F.assert_equal(:bound, execution.request_match[:state])
    end
    %w[Ala Anna Bartek Beata].each do |actor|
      F.with_execution(fixture, actor) do |execution|
        F.select_execution(execution, record)
        binding = execution.admission(action: :admission_status)[:status]['binding']
        consent = execution.admission(action: :consent, binding_digest: F::T::CoordinationContract.digest(binding))[:effect]
        F.assert_equal(:confirmed, execution.admission(action: :enter, consent_id: consent['id'])[:state])
      end
    end
    F.with_execution(fixture, 'Ala') do |execution|
      F.select_execution(execution, record)
      binding = execution.admission(action: :admission_status)[:status]['binding']
      F.assert_equal(:confirmed, execution.local_game(action: :start_local_game,
        binding_digest: F::T::CoordinationContract.digest(binding))[:state])
    end
    fixture
  end
end
