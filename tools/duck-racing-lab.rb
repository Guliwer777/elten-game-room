# frozen_string_literal: true

# Optional, source-only manual challenge laboratory. Never require this file
# from the application: tools/ is excluded from the release allowlist.
#
# Load the file into EACH participating application's namespace after the
# ordinary sources. Create a private Duck Racing table with "Challenge lab
# (test only)" checked, then start normally. The playing host selects a
# challenge with arrows/Enter; a two-player challenge asks for a pair. Once
# the result is settled the same list returns. No race cards or rolls run in
# between. The lab keeps the real feather balances and normal settlements.
# Frozen players may take part in lab challenges; no feathers are invented.
# Both clients need this file for the lifetime of the table/saved test game.
# A normal application reload removes the tool. It does not alter profiles.

raise 'Load Duck Racing before its optional lab tool' unless defined?(GameRoomGames::DuckRacing)

unless defined?(GameRoomDuckRacingLab::VERSION)
  module GameRoomDuckRacingLab
    VERSION = 1
    OPTION = 'duck_challenge_lab'
    ACTION = 'lab_challenge'
    ZONE = 'duck_challenge_lab'
    THREAD_KEY = :power_games_optional_duck_lab

    module_function

    def text(english, polish)
      GameRoomContent.utf8(GameRoomLocalization.primary_language == 'pl' ? polish : english)
    end

    def enabled?(state)
      state.is_a?(Hash) && state[:duck_challenge_lab] == true
    end

    def idle?(state)
      race = state && state[:race]
      enabled?(state) && race && state[:round].nil? && race[:phase] == :turn &&
        race[:challenge].nil? && race[:pending].empty? && race[:continuation].nil? &&
        !race[:rolled] && !race[:card_played]
    end

    def lab_action?(data)
      data.is_a?(Hash) && data['action'] == 'race' && data['input'].is_a?(Hash) &&
        data['input']['kind'] == ACTION
    end

    def scope
      entry = Thread.current[THREAD_KEY]
      entry && entry.first.equal?(self) ? entry.last : nil
    end

    def within(value)
      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = [self, value]
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def selection(replay, kind, seats)
      {'kind' => 'duck', 'action' => 'race', 'input' => {
        'kind' => ACTION, 'type' => kind, 'seats' => seats,
        'revision' => replay.state[:revision], 'session' => replay.state[:session_id],
        'epoch' => replay.state[:bot_controller_epoch]
      }}
    end

    # Record provenance is supplied by the existing decoder/repository, never
    # by a field claiming to be the host in the game's JSON. Seat changes map
    # the historical controller to its stable seat, not to its current name.
    def replay_authority(current, actor, batch, repository)
      session = current.fetch(:session)
      source = current.fetch(:events).fetch(repository.event_id(batch.first), batch.first)
      owner = source['__authority_user'] || session['__table_owner'] || current[:players].first
      author = source['__insertion_user'] || source['actor']
      if source['__controller'] == true && source['move_id'].to_s.start_with?('archive:')
        return current[:players].index { |name| GameRoomParticipants.same?(name, actor) }
      end
      return unless GameRoomParticipants.same?(author, owner) &&
        GameRoomParticipants.same?(current[:repository].actor_of(source, session), author) &&
        !GameRoomParticipants.bot?(author)

      roster = GameRoomParticipantReplay.roster_at(session, current[:repository].event_id(source))
      roster.index { |name| GameRoomParticipants.same?(name, author) }
    end

    module PayloadHook
      def each(events, action, repository, session, &block)
        current = GameRoomDuckRacingLab.scope
        return super unless action == 'duck_racing' && current && current[:enabled] && current[:events]

        super do |data, actor, batch|
          previous = current.values_at(:authorized_seat, :historical)
          source = current[:events].fetch(repository.event_id(batch.first), batch.first)
          current[:historical] = current[:physical_id].nil? ||
            source['__controller'] == true && source['move_id'].to_s.start_with?('archive:')
          current[:authorized_seat] = GameRoomDuckRacingLab.replay_authority(current, actor, batch, repository)
          begin
            block.call(data, actor, batch)
          ensure
            current[:authorized_seat], current[:historical] = previous
          end
        end
      end
    end

    # Reuse the actual race's challenge factory/RNG/snapshot. The lab's one
    # deliberate eligibility exception is temporary and restored before any
    # state is published; freezing and settlement themselves are unchanged.
    def open_challenge(state, kind, seats, now_ms)
      race = state.fetch(:race)
      frozen = race[:racers].transform_values { |racer| racer[:frozen_turns] }
      begin
        race[:racers].each_value { |racer| racer[:frozen_turns] = 0 }
        race[:notices] = []
        GameRoomDuckRacing::Race.new(race).send(:start_challenge, seats, trigger: :laboratory, kind: kind)
      ensure
        frozen.each { |seat, turns| race[:racers].fetch(seat)[:frozen_turns] = turns }
      end
      race[:revision] += 1
      state[:notices] = race[:notices].dup
      GameRoomDuckRacing::Session.send(:open_challenge, state, now_ms)
      state[:revision] += 1
      true
    end

    module SessionHook
      def initial(**arguments)
        state = super
        state[:duck_challenge_lab] = true if GameRoomDuckRacingLab.scope&.[](:enabled)
        state
      end

      def apply(state, data, seat:, moderator:, now_ms:, resources: {})
        lab = GameRoomDuckRacingLab
        # Race moves are not a back door to auto-rolling a lab table, even if
        # a caller bypasses the list and submits an ordinary card/roll packet.
        return false if lab.enabled?(state) && data.is_a?(Hash) && data['action'] == 'race' && !lab.lab_action?(data)
        return super unless lab.lab_action?(data)
        input, current = data['input'], lab.scope
        return false unless lab.idle?(state) && moderator && current && current[:enabled] &&
          current[:authorized_seat] == seat && seat.is_a?(Integer) && seat.between?(0, state[:player_count] - 1)
        return false unless data.keys.all? { |key| key.is_a?(String) } &&
          data['revision'] == state[:revision] && input['revision'] == state[:revision] &&
          data['session'].is_a?(Integer) && data['session'].positive? && input['session'] == data['session'] &&
          now_ms.is_a?(Integer) && now_ms >= 0 &&
          (input.keys - %w[kind type seats revision session epoch]).empty?
        return false unless current[:historical] || data['session'] == current[:physical_id]
        type = GameRoomDuckRacing::Challenges::BY_ID[input['type']]
        seats = input['seats']
        return false unless type && state[:enabled_challenges].include?(type.id) && seats.is_a?(Array) &&
          seats.all? { |value| value.is_a?(Integer) && value.between?(0, state[:player_count] - 1) } &&
          seats == seats.uniq.sort && seats.length.between?(type.minimum_players, type.maximum_players)
        return false unless type.maximum_players == 2 || seats == (0...state[:player_count]).to_a

        state[:protocol_session] = data['session']
        lab.open_challenge(state, type.id, seats, now_ms)
      end
    end

    module GameHook
      def option_definitions
        super + [GameRoomGames::OptionDefinition.new(key: OPTION,
          label: GameRoomDuckRacingLab.text('Challenge lab (test only)', 'Laboratorium wyzwań (tylko do testów)'),
          kind: :boolean, default: false)]
      end

      def normalize_options(values)
        result = super
        # Ordinary tables retain their exact previous option representation.
        result.delete(OPTION) unless result[OPTION] == true
        result
      end

      def replay(session, events, repository)
        return super unless options_from_json(session['options'])[OPTION] == true
        rows = events.to_a
        current = {enabled: true, session: session, players: repository.players_for(session),
          physical_id: session['__id'] || session['id'], repository: repository,
          events: rows.to_h { |event| [repository.event_id(event), event] }}
        GameRoomDuckRacingLab.within(current) { super(session, rows, repository) }
      end

      def action_for(selection, replay, actor, context: nil)
        raw = selection.to_h.transform_keys(&:to_s)
        if raw['kind'] == 'card' && raw['action'] == 'select' && raw['zone'] == ZONE
          return [:invalid, nil] unless raw['card'].is_a?(Hash)
          raw = raw['card']
        end
        return super unless GameRoomDuckRacingLab.lab_action?(raw)

        state, input = replay.state, raw['input']
        seat = player_index(replay.players, actor)
        return [:invalid, nil] unless GameRoomDuckRacingLab.idle?(state) && context && seat &&
          same_user?(actor, state[:owner]) && same_user?(actor, context.table_owner) &&
          !GameRoomParticipants.bot?(actor) && context.local_data.to_h['duck_host'] == true &&
          context.local_data.to_h['duck_seat'] == seat && context.session_id == state[:session_id] &&
          input['session'] == state[:session_id] && input['revision'] == state[:revision] &&
          input['epoch'] == state[:bot_controller_epoch]

        GameRoomDuckRacingLab.within(enabled: true, authorized_seat: seat, physical_id: state[:session_id]) do
          super(raw, replay, actor, context: context)
        end
      end

      def surface_spec(replay, viewer)
        return super unless GameRoomDuckRacingLab.idle?(replay.state)
        unless same_user?(viewer, replay.state[:owner]) && player_index(replay.players, viewer) &&
            !GameRoomParticipants.bot?(viewer)
          return info_surface(GameRoomDuckRacingLab.text('The host chooses the next test.', 'Gospodarz wybiera kolejne wyzwanie.'))
        end
        seats = (0...replay.players.length).to_a
        cards = GameRoomDuckRacing::Challenges::TYPES.filter_map do |type|
          next unless replay.state[:enabled_challenges].include?(type.id)
          pairs = type.maximum_players == 2 && seats.length > 2 ? seats.combination(2).to_a : []
          choices = pairs.map do |pair|
            GameSurfaces::CardChoice.new(id: pair.join(':'),
              label: pair.map { |seat| participant_name(replay.players.fetch(seat)) }.join(' / '),
              value: GameRoomDuckRacingLab.selection(replay, type.id, pair))
          end
          GameSurfaces::Card.new(id: type.id, label: challenge_name(type.id), choices: choices,
            choice_header: GameRoomDuckRacingLab.text('Choose two players', 'Wybierz dwóch graczy'),
            value: GameRoomDuckRacingLab.selection(replay, type.id, seats))
        end
        GameSurfaces::CardTableSpec.new(zones: [GameSurfaces::CardZoneSpec.new(id: ZONE,
          header: GameRoomDuckRacingLab.text('Challenge lab: choose a test and press Enter',
            'Laboratorium wyzwań: wybierz próbę i naciśnij Enter'), cards: cards)])
      end

      def active_actors(replay)
        return [] if GameRoomDuckRacingLab.enabled?(replay.state) && replay.state[:round].nil?
        super
      end

      def legal_actions(replay, actor, context: nil)
        return [] if GameRoomDuckRacingLab.enabled?(replay.state) && replay.state[:round].nil?
        super
      end

      def automatic_action(replay, actor, context: nil)
        return if GameRoomDuckRacingLab.enabled?(replay.state) && replay.state[:race] && replay.state[:round].nil?
        super
      end

      def custom_game_shortcuts(replay, viewer)
        list = super
        GameRoomDuckRacingLab.idle?(replay.state) ? list.reject { |shortcut| shortcut.key == 'd' } : list
      end

      def turn_text(replay)
        return super unless GameRoomDuckRacingLab.idle?(replay.state)
        GameRoomDuckRacingLab.text('The host chooses the next test.', 'Gospodarz wybiera kolejne wyzwanie.')
      end
    end
  end

  GameRoomGames::DuckRacing.prepend(GameRoomDuckRacingLab::GameHook)
  GameRoomDuckRacing::Session.singleton_class.prepend(GameRoomDuckRacingLab::SessionHook)
  GameRoomActionPayload.singleton_class.prepend(GameRoomDuckRacingLab::PayloadHook)
end
