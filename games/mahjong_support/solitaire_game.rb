# frozen_string_literal: true
require_relative '../base'
require_relative 'solitaire'
require_relative 'tiles'
require_relative '../mahjong_rules'

module GameRoomGames
  using GameRoomLocalization::Translations

  # Internal solitaire adapter for the future single Mahjong catalog entry.
  # Does not register a second game or add a second execution loop.
  module MahjongSolitaireGame
    include MahjongRules
    SOLITAIRE_EVENT_KEYS = {'v'=>'v', 'action'=>'a', 'turn'=>'t', 'seed'=>'r', 'first'=>'f', 'second'=>'s'}.freeze
    def mahjong_rulebook_scope; :solitaire; end
    def build_presentation_game
      build_session_game
    end

    def replay(session, events, repository)
      players = repository.players_for(session).dup.freeze
      raise ArgumentError, 'Solitaire requires one occupied seat' unless players.length == 1
      options = options_from_json(session['options'])
      layout = options.fetch('layout', 'terraces')
      raise ArgumentError, 'Unknown mahjong solitaire layout' unless GameRoomMahjong::Solitaire::LAYOUTS.include?(layout)
      session_id = repository.respond_to?(:session_id) ? repository.session_id(session) : (session['__id'] || session['id'])
      identity_supplied = repository.respond_to?(:session_id) || session.key?('__id') || session.key?('id')
      if identity_supplied && !(session_id.is_a?(Integer) && session_id.positive?)
        raise ArgumentError, 'Invalid solitaire session'
      end
      @mahjong_solitaire_repository = repository
      state = {session_id: session_id, players: players, layout: layout.dup.freeze, phase: :awaiting_deal,
        board: nil, turn: 0, moves: [].freeze, winner: nil, draw: false}.freeze
      reduce_solitaire(state, [], [starting_history(players)], events, session, repository)
    end

    def incremental_replay(previous, session, events, repository)
      return nil unless previous && previous.state
      return nil unless repository.respond_to?(:session_id) && @mahjong_solitaire_repository.equal?(repository) && previous.state[:session_id] == repository.session_id(session)
      return nil unless repository.players_for(session) == previous.players
      layout = options_from_json(session['options']).fetch('layout', 'terraces')
      return nil unless previous.state[:layout] == layout
      reduce_solitaire(previous.state, previous.accepted_events.dup, previous.history.dup,
        events, session, repository)
    end

    def action_for(selection, replay, actor, context: nil)
      return [:finished, nil] if replay.finished?
      return [:not_your_turn, nil] unless same_user?(actor, replay.players.first)
      return [:stale, nil] if context && context.session_id != replay.state[:session_id]
      input = selection.to_h
      if context&.server_random && replay.state[:phase] == :awaiting_deal &&
          input.values_at('kind', 'action', 'turn') == ['command', 'deal', 0]
        command = GameRoomServerRandom.recipe_command(action: 'mahjong', kind: 'seed_json',
          data: {'v'=>1, 't'=>0, 'a'=>'deal'})
        return [:ok, ActionPlan.new(events: [command])]
      end
      data = solitaire_input(selection, replay.state, context)
      return [:invalid, nil] unless data
      status, = solitaire_apply(replay.state, data)
      return [status, nil] unless status == :ok
      value = JSON.generate(data.transform_keys { |key| SOLITAIRE_EVENT_KEYS.fetch(key) })
      return [:invalid, nil] if value.bytesize > 64
      [:ok, event_plan('mahjong', value)]
    end

    def automatic_action(replay, actor, context: nil)
      return nil unless replay && replay.state[:phase] == :awaiting_deal && same_user?(actor, replay.players.first)
      {'kind'=>'command', 'action'=>'deal', 'turn'=>replay.state[:turn]}
    end

    def automatic_action_due?(replay, actor, context: nil)
      !automatic_action(replay, actor, context: context).nil?
    end

    def legal_actions(replay, actor, context: nil)
      return [] if replay.finished? || replay.state[:phase] != :playing || !same_user?(actor, replay.players.first)
      state = replay.state
      state[:board].pairs.map do |first, second|
        {'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-pairs:#{state[:turn]}", 'answer'=>"#{first}:#{second}"}
      end
    end

    def participant_scores(replay)
      {replay.players.first => replay.state[:moves].length}
    end

    private

    def solitaire_input(selection, state, context)
      input = selection.to_h
      data = {'v'=>1, 'turn'=>state[:turn]}
      if input['kind'] == 'question' && input['action'] == 'submit'
        return nil unless input['question_id'] == "mahjong-pairs:#{state[:turn]}" && input['answer'].is_a?(String)
        match = /\A(0|[1-9][0-9]{0,2}):(0|[1-9][0-9]{0,2})\z/.match(input['answer'])
        return nil unless match
        data.merge!('action'=>'remove', 'first'=>Integer(match[1], 10), 'second'=>Integer(match[2], 10))
      elsif input['kind'] == 'command'
        return nil unless input['turn'].is_a?(Integer) && input['turn'] == state[:turn]
        data['action'] = input['action']
        if data['action'] == 'deal'
          return nil unless context&.random_source
          values = context.random_source.roll(count: 8, sides: 256).values
          return nil unless values.is_a?(Array) && values.length == 8 && values.all? { |value| value.is_a?(Integer) && value.between?(1, 256) }
          data['seed'] = values.reduce(0) { |seed, value| (seed << 8) | (value - 1) } & ((1 << 63) - 1)
        end
      else
        return nil
      end
      solitaire_valid_data?(data) ? data : nil
    end

    def solitaire_valid_data?(data)
      return false unless data.is_a?(Hash) && data['v'].is_a?(Integer) && data['v'] == 1 &&
        data['turn'].is_a?(Integer) && data['turn'].between?(0, (1 << 63) - 1)
      extra = {'deal'=>['seed'], 'remove'=>['first', 'second'], 'undo'=>[], 'surrender'=>[]}[data['action']]
      return false unless extra && data.keys.sort == (['v', 'turn', 'action'] + extra).sort
      case data['action']
      when 'deal' then data['seed'].is_a?(Integer) && data['seed'].between?(0, (1 << 63) - 1)
      when 'remove' then %w[first second].all? { |key| data[key].is_a?(Integer) && data[key].between?(0, 143) }
      else true
      end
    end

    def solitaire_decode(value)
      return nil unless value.is_a?(String) && value.bytesize <= 64
      wire = JSON.parse(value, max_nesting: 4)
      return nil unless wire.is_a?(Hash) && (wire.keys - SOLITAIRE_EVENT_KEYS.values).empty?
      data = wire.transform_keys { |key| SOLITAIRE_EVENT_KEYS.key(key) }
      solitaire_valid_data?(data) ? data : nil
    rescue JSON::ParserError
      nil
    end

    def solitaire_apply(state, data)
      return [:stale, state] unless data['turn'] == state[:turn]
      return [:finished, state] if state[:phase] == :finished
      changes = {turn: state[:turn] + 1}
      case data['action']
      when 'deal'
        return [:invalid, state] unless state[:phase] == :awaiting_deal
        @mahjong_solitaire_deals ||= {}
        key = [state[:layout], data['seed']]
        board = @mahjong_solitaire_deals[key]
        unless board
          board = GameRoomMahjong::Solitaire.deal(seed: data['seed'], layout: state[:layout]).game
          @mahjong_solitaire_deals.shift if @mahjong_solitaire_deals.length >= 4
          @mahjong_solitaire_deals[key] = board
        end
        changes.merge!(board: board, phase: :playing)
      when 'remove'
        return [:invalid, state] unless state[:phase] == :playing
        first, second, board = data['first'], data['second'], state[:board]
        return [:invalid, state] if first == second
        return [:blocked_tile, state] unless board.free?(first) && board.free?(second)
        return [:different_tiles, state] unless GameRoomMahjong::Tiles.match?(board.tiles[first], board.tiles[second])
        next_board = board.remove(first, second)
        changes.merge!(board: next_board, moves: (state[:moves] + [[first, second].freeze]).freeze)
        changes.merge!(phase: :finished, winner: state[:players].first) if next_board.finished?
      when 'undo'
        return [:invalid, state] unless state[:phase] == :playing && !state[:moves].empty?
        board = state[:board]
        pair = state[:moves].last
        restored = GameRoomMahjong::Solitaire.new(positions: board.positions, tiles: board.tiles, remaining: board.remaining + pair)
        changes.merge!(board: restored, moves: state[:moves][0...-1].freeze)
      when 'surrender'
        return [:invalid, state] unless state[:phase] == :playing
        changes.merge!(phase: :finished, draw: true)
      else return [:invalid, state]
      end
      [:ok, state.merge(changes).freeze]
    end

    def reduce_solitaire(state, accepted, history, events, session, repository)
      seen = accepted.to_h { |event| [repository.event_id(event).to_i, true] }
      events.each do |event|
        event_id = repository.event_id(event).to_i
        next if event_id <= 0 || seen[event_id] || event['action'] != 'mahjong'
        next unless same_user?(repository.actor_of(event, session), state[:players].first)
        data = solitaire_decode(event['value'])
        next unless data
        status, next_state = solitaire_apply(state, data)
        next unless status == :ok
        history << solitaire_history(data, state, event_id)
        state = next_state
        accepted << event
        seen[event_id] = true
      end
      Replay.new(board: nil, players: state[:players], current_player: state[:phase] == :finished ? nil : state[:players].first,
        winner: state[:winner], draw: state[:draw], accepted_events: accepted, history: history, state: state)
    end

    def solitaire_history(data, state, event_id)
      text = case data['action']
      when 'deal' then _('The mahjong solitaire puzzle is ready.')
      when 'remove' then _('Removed a matching pair of tiles.')
      when 'undo' then _('Restored the previous pair of tiles.')
      when 'surrender' then _('The mahjong solitaire puzzle was ended.')
      end
      HistoryEntry.new(key: "mahjong:#{event_id}", event_id: event_id,
        actor: state[:players].first, kind: data['action'].to_sym, text: GameRoomContent.utf8(text))
    end
  end
end
