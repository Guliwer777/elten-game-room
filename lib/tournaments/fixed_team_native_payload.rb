# encoding: UTF-8
require_relative 'coordination_request'
require_relative 'fixed_team_seats'

module GameRoomTournaments
  # Pochodne metadane modelu; bez grantu, powiązania stołu lub prawa startu.
  class FixedTeamNativePayload
    def self.from_execution_plan(evidence:, expected_source:, match_id:, leg:, window_id:, registry:)
      selectors = Publication::Data.freeze_tree(Publication::Data.copy({'match_id' => match_id, 'leg' => leg, 'window_id' => window_id}))
      data = ExecutionPlanContract.copy(evidence)
      anchor = ExecutionPlanContract.copy(expected_source)
      raise Publication::Invalid, :wersja_planu unless data.is_a?(Hash) && data['version'].eql?(2)
      request = CoordinationRequest.from_execution_plan(evidence: data, expected_source: anchor,
        match_id: selectors['match_id'], leg: selectors['leg'], window_id: selectors['window_id'], registry: registry)
      value = request.to_h
      people = value['players'].sort_by { |person| person['seat'] }
      options = FixedTeamSeats.native(game: registry.build(value['game_id']), options: value['options'],
        people: people, template: data['source']['team_template'], unit_size: FixedTeamSeats.unit_size(data['source']['membership']))
      new(Publication::Data.freeze_tree(ExecutionPlanContract.copy({'request_digest' => request.digest,
        'players' => people.map { |person| person['username'] }, 'options' => options,
        'dispatch_allowed' => false, 'start_allowed' => false})))
    end

    def initialize(data)
      @data = data
      @digest = ExecutionPlanContract.digest(data).freeze
      freeze
    end
    private_class_method :new

    def to_h
      @data
    end

    def digest
      @digest
    end
  end
end
