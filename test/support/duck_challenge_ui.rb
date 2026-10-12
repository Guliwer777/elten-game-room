require 'base64'
require 'zlib'
require_relative 'assertions'
require_relative '../../games/duck_racing_support/challenge_engine'

module DuckChallengeTest
  include GameRoomTest::Assertions
  ENGINE = GameRoomDuckRacing::ChallengeEngine

  def challenge_resources
    @challenge_resources ||= begin
      registry = GameRoomContent::Registry.new
      language = GameRoomContent::LanguageProfile.new(id: 'en', label: 'English', alphabet: ('a'..'z').to_a,
        normalizer: ->(word) { word.downcase })
      registry.register_language(language)
      registry.register_pack(GameRoomContent::Pack.new(id: 'duck.quiz.test', set_id: 'duck.quiz',
        kind: 'quiz', language_id: 'en', version: 1, title: 'Test', game_ids: ['quiz'], data: {'questions' => [
          {'id' => 'sample', 'category' => 'Testing', 'prompt' => 'Which answer?', 'correct' => 'Answer',
            'wrong' => %w[first second third]}]}))
      questions = GameRoomDuckRacing::QuestionSets.prepare_selected(ids: ['duck.quiz'], language: 'en', registry: registry)
      {questions: questions}
    end
  end

  def challenge_state(kind, seed: 7)
    ENGINE.start({kind: kind, seed: seed, participants: [0, 1], race_snapshot: {board_length: 30,
      racers: {0 => {progress: 4, feathers: 10, card_count: 3, die_sides: 6, die_rolls: 0},
        1 => {progress: 8, feathers: 16, card_count: 4, die_sides: 6, die_rolls: 0}}}}, resources: challenge_resources)
  end

  def challenge_surface(model, seat: 0, id: 'challenge-one')
    GameSurfaces.build(GameSurfaces::DuckChallengeSpec.new(challenge_id: id, kind: model[:kind], viewer: seat,
      view: ENGINE.view(model, seat: seat)))
  end

  def acknowledge_challenge(model, seat: 0, now_ms: 1)
    request = ENGINE.stimulus(model, seat: seat)
    assert(request, 'No challenge stimulus')
    if model[:kind] == 'hit_duck'
      assert(ENGINE.submit(model, seat: seat, action: {kind: :playback_started, playback_id: request[:id]},
        now_ms: now_ms, resources: challenge_resources), 'Could not start the fixture playback')
    end
    assert(ENGINE.submit(model, seat: seat, action: {kind: :playback_finished, playback_id: request[:id]},
      now_ms: now_ms, resources: challenge_resources), 'Could not finish the fixture playback')
  end
end
