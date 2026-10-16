# encoding: UTF-8
require_relative 'game_result'
require_relative 'strict_json'
require 'digest'

module GameRoomTournaments
  # Automatic export of one explicitly bound ordinary game's verified history.
  class OrdinaryMatchResults
    def self.read(repository:, registry:, transport:, table:, binding:)
      binding = Publication::Data.copy(binding)
      unless table['__id'] == binding['table']['__id'] && table['__live_session_id'] == binding['table']['__live_session_id']
        raise Publication::Invalid, :wrong_game_table
      end
      session = repository.session_by_id(binding.fetch('session_id'), table: table)
      return nil unless session
      snapshot = session && repository.snapshot_for(session, force_events: true)
      raise Publication::Invalid, :missing_bound_session unless snapshot
      session = snapshot.session
      unless session['table_id'] == table['__id'] && session['game'] == binding['game_id'] &&
          !session['__aborted'] && !session['__frozen'] && (!session['__restored'] || binding.key?('continuation'))
        raise Publication::Invalid, :wrong_bound_session
      end
      game = registry.build(binding['game_id'])
      replay = game.replay(session, snapshot.events, repository)
      return nil unless replay.finished?
      capture(registry:registry,binding:binding,session:session,replay:replay,events:snapshot.events)
    end

    def self.capture(registry:, binding:, session:, replay:, events:)
      unless session['__id']==binding['session_id'] && session['table_id']==binding['table']['__id'] && session['game']==binding['game_id'] &&
          !session['__aborted'] && !session['__frozen'] && valid_continuation?(binding,session,events)
        raise Publication::Invalid,:wrong_bound_session
      end
      game=registry.build(binding['game_id'])
      options=game.normalize_options(StrictJson.parse(session.fetch('options'),max_nesting:12))
      expected=game.normalize_options(binding.fetch('options'))
      normalize_roster=->(value) do
        if value.key?('team_players') && !value['team_players'].is_a?(Array)
          raise Publication::Invalid,:wrong_game_options
        end
        value.key?('team_players') ? value.merge('team_players'=>value['team_players'].map{|name|Publication::Data.account(name).downcase}) : value
      end
      raise Publication::Invalid,:wrong_game_options unless normalize_roster.call(options)==normalize_roster.call(expected)
      players=binding.fetch('players')
      summary = GameResult.from_replay(game: game, replay: replay, players: players, options: options,
        event_count: events.size, result_policy: GameResult::CURRENT_RESULT_POLICY)
      Publication::Data.freeze_tree({'kind' => 'ordinary-match-result-v1', 'binding_digest' => Digest::SHA256.hexdigest(JSON.generate(binding)),
        'match_id' => binding['match_id'], 'leg' => binding['leg'], 'session_id' => binding['session_id'],
        'history_digest' => Digest::SHA256.hexdigest(JSON.generate(events)), 'summary' => summary})
    end
    def self.valid_continuation?(binding,session,events)
      marker=binding['continuation']
      return !session['__archive_id'] unless marker
      marker.is_a?(Hash) && marker['archive_id']==session['__archive_id'] &&
        marker['event_count'].is_a?(Integer) && marker['event_count']>=0 && events.size>=marker['event_count'] &&
        marker['prefix_digest']==Digest::SHA256.hexdigest(JSON.generate(events.first(marker['event_count']).map{|event|event.slice('actor','action','value')}))
    end
  end
end
