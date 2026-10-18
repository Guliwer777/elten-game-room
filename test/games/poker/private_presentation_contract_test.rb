require_relative '../../support/private_card_games'
require_relative '../../../games/poker'
require_relative '../../../lib/game_event_presenter'

%w[holdem draw].each do |variant|
  game = GameRoomGames::Poker.new
  h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob], options: {'variant' => variant})
  begin
    h.add_client('Watcher')
    assert(h.join('Watcher'), 'Observer did not join')
    %w[Alice Bob Watcher].each do |user|
      repository = h.repositories[user]
      snapshot = repository.snapshot_for(h.session)
      rep = game.replay(snapshot.session, snapshot.events, repository)
      descriptions = snapshot.events.flat_map { |event| Array(game.describe_event(event, repository, rep, user)) }
      own = descriptions.grep(/^Cards in hand:/)
      assert(own.length == (user == 'Watcher' ? 0 : 1), "#{variant}/#{user}: missing or duplicate own hand")
      if user != 'Watcher'
        expected = rep.state[:hands][user].sort_by { |card| game.send(:playing_sort_key, card) }.
          map { |card| game.send(:poker_card_label, card) }.join(', ')
        assert(own == ["Cards in hand: #{expected}."], "#{variant}/#{user}: announcement is not the authenticated own draw")
      end
      assert(rep.history.none? { |entry| entry.text.start_with?('Cards in hand:') }, 'Own cards entered shared history')
      unavailable = game.replay(snapshot.session.merge('__private_draws' => {}), snapshot.events, repository)
      assert(snapshot.events.flat_map { |event| Array(game.describe_event(event, repository, unavailable, user)) }.
        none? { |text| text.start_with?('Cards in hand:') || text.include?('hidden:') },
        "#{variant}/#{user}: unavailable private values were spoken")
      receipt = snapshot.events.find { |event| event['action'] == 'initial_hand' && repository.actor_of(event) == user }
      if receipt
        fake = receipt.merge('__id' => 99999)
        assert(Array(game.describe_event(fake, repository, rep, user)).none? { |text| text.start_with?('Cards in hand:') },
          'A nonaccepted receipt announced the hand')
      end

      # Exercise the production presenter, including backlog descriptions,
      # repeated snapshots and cold reconstruction (no replayed old audio).
      spoken, sounds = [], []
      program = Object.new
      program.define_singleton_method(:play_sound_from_asset) { |asset, **_options| sounds << asset; nil }
      presenter = GameRoomEventPresenter.new(game: -> { game }, repository: -> { repository },
        program: -> { program }, viewer: -> { user }, client: -> { nil }, surface_state: -> { {} },
        clock: -> { 0.0 }, covered: -> { false }, speech: ->(text) { spoken << text },
        trace: ->(*) {}, history_changed: ->(*) {}, session_changed: -> {})
      presenter.last_seen_event_id = 0
      presenter.process_new_events(rep, session: snapshot.session)
      assert(spoken.grep(/^Cards in hand:/) == own, "#{variant}/#{user}: presenter lost or repeated the own hand")
      assert(sounds.count('shuffle') == 1, 'The accepted deal did not use the real sound output path')
      previous = spoken.dup
      previous_sounds = sounds.dup
      presenter.process_new_events(rep, session: snapshot.session)
      assert(spoken == previous && sounds == previous_sounds, 'Repeated snapshot replayed speech or audio')
      presenter.last_seen_event_id = nil
      presenter.process_new_events(rep, session: snapshot.session)
      assert(spoken == previous && sounds == previous_sounds, 'Cold reconstruction repeated old deal speech or audio')
    end
  ensure
    runners.each_value(&:close)
  end
end

puts 'PASS private Poker presentation: only authenticated own cards, unavailable/foreign/observer silence, real presenter, repeated snapshot and cold reconstruction'
