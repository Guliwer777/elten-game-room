# frozen_string_literal: true

require_relative "question_sets"
require_relative "../../content/languages"
require_relative "../../content/quiz_general_en"
require_relative "../../content/quiz_general_ru"
require_relative "../../content/quiz_pl_wikidata"
require_relative "../../content/quiz_witcher_pl"
require "thread"

module GameRoomDuckRacing
  # Prepare the selected question packs once before an attempt. Word
  # challenges are not offered; do not load their dictionaries into the race.
  module Resources
    MAX_SELECTIONS = 8
    @lock = Mutex.new
    @prepared = {}
    module_function

    def prepare(options, registry: GameRoomContent.registry)
      packs = QuestionSets.selected_packs(ids: options.fetch("question_sets"),
        language: options.fetch("question_language"), registry: registry)
      # Registry.build creates a new game even for a label/option lookup.
      # Share only verified immutable content, never clients or replay state.
      # Actual pack/profile identities invalidate the cache after a reload or
      # a replacement registry, even when IDs and version labels are reused.
      key = packs.map { |pack| [pack, registry.language(pack.language_id)].freeze }.freeze
      cached = @lock.synchronize { @prepared[key] }
      return cached if cached
      questions = QuestionSets.prepare_selected(ids: options.fetch("question_sets"),
        language: options.fetch("question_language"), registry: registry)
      prepared = {questions: questions, fingerprint: questions.fingerprint}.freeze
      # Loading/validation is outside the cache mutex. Concurrent cold callers
      # may validate twice, but a slow load never holds the lookup lock.
      @lock.synchronize do
        @prepared[key] ||= prepared
        @prepared.shift while @prepared.size > MAX_SELECTIONS
        @prepared.fetch(key)
      end
    end
  end
end
