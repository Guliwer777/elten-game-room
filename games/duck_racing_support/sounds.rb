# frozen_string_literal: true

require_relative '../../lib/duck_racing/quiz_sounds'
require_relative '../../lib/duck_racing/answer_sounds'

module GameRoomGames
  class DuckRacing
    EVENT_SOUNDS = {
      started: 'shuffle', rolled: 'roll', played: 'play', placed: 'play',
      drew_cards: 'draw', stole_card: 'draw', swapped_hands: 'card-shuffle',
      passed_hands: 'card-shuffle', skipped: 'skip', frozen: 'duck_frozen',
      challenge: 'duck_challenge', quiz_question: 'duck_question', final_lap: 'duck_final_lap',
      challenge_roll: 'roll', challenge_draw: 'draw', challenge_hand: 'draw'
    }.freeze

    def event_sound_cues(event:, before_replay:, after_replay:, history:, viewer:, random_variant:)
      # History belongs to the accepted event's final payload fragment. The
      # shared presenter owns its cursor; snapshots, partial payloads and
      # reconstruction must not replay a roll or every private attempt.
      cues = history.filter_map do |entry|
        if entry.kind == :trap && entry.value == 'mine'
          'hit_ship1'
        elsif entry.kind == :skipped && entry.value == true
          'duck_frozen'
        else
          EVENT_SOUNDS[entry.kind]
        end
      end
      cues << GameRoomDuckRacing::QuizSounds.result_cue(before_replay: before_replay,
        after_replay: after_replay, history: history, viewer: viewer)
      cues << GameRoomDuckRacing::AnswerSounds.result_cue(before_replay: before_replay,
        after_replay: after_replay, history: history, viewer: viewer)
      cues.compact.uniq
    end
  end
end
