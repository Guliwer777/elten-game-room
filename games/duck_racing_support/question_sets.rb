# frozen_string_literal: true

require_relative "../../lib/game_content"
require_relative "../../lib/game_random"

module GameRoomDuckRacing
  module QuestionSets
    class Unavailable < ArgumentError; end
    PUBLIC_FIELDS = %i[set_id pack_id pack_version pack_checksum language_id question_id category prompt choices].freeze
    GENERAL_SET_IDS = { "en" => "quiz.general", "pl-PL" => "quiz.wikidata", "ru-RU" => "quiz.general.ru" }.freeze

    module_function

    # Metadata only: opening the checklist must not parse every question pack.
    # Each set retains its stable ID; language variants stay explicit, never
    # chosen through the interface language or a first-available fallback.
    def catalog(registry: GameRoomContent.registry)
      registry.pack_sets_for(game_id: "quiz", kind: "quiz").map do |set|
        {
          set_id: set.id, title: set.title,
          languages: set.packs.map do |pack|
            {
              language_id: pack.language_id,
              language_label: registry.language(pack.language_id).label,
              pack_id: pack.id, version: pack.version,
              question_count: pack.entry_count
            }
          end
        }
      end
    end

    def choices(language:, registry: GameRoomContent.registry)
      catalog(registry: registry).filter_map do |entry|
        variant = entry[:languages].find { |candidate| candidate[:language_id] == language }
        { value: entry[:set_id], label: entry[:title], question_count: variant[:question_count] } if variant
      end
    end

    # Defaults are an explicit editorial choice, not the first catalogue item.
    # A missing general set is an error even if a specialist set is installed.
    def languages(registry: GameRoomContent.registry)
      GENERAL_SET_IDS.filter_map do |language, id|
        language if registry.pack_for(game_id: "quiz", kind: "quiz", set_id: id, language_id: language)
      end
    end

    def defaults(language, registry: GameRoomContent.registry)
      id = GENERAL_SET_IDS[language]
      unless id && registry.pack_for(game_id: "quiz", kind: "quiz", set_id: id, language_id: language)
        raise Unavailable, "The general question set for #{language} is unavailable"
      end
      [id]
    end

    def selected_packs(ids:, language:, registry: GameRoomContent.registry)
      unless language.is_a?(String) && !language.empty?
        raise Unavailable, "Select the question language"
      end
      unless ids.is_a?(Array) && !ids.empty? && ids.all? { |id| id.is_a?(String) && !id.empty? } && ids.uniq.length == ids.length
        raise Unavailable, "Select at least one question set without duplicate identifiers"
      end
      ids.sort.map do |id|
        registry.pack_for(game_id: "quiz", kind: "quiz", set_id: id, language_id: language) ||
          raise(Unavailable, "Selected question set #{id}/#{language} is unavailable")
      end
    end

    def prepare_selected(ids:, language:, registry: GameRoomContent.registry)
      selected_packs(ids: ids, language: language, registry: registry)

      prepare(selection: ids.to_h { |id| [id, language] }, weights: ids.to_h { |id| [id, 1] }, registry: registry)
    end

    # selection: { stable_set_id => exact_language_id }
    # weights:   { stable_set_id => positive_integer }
    # Both are required for the lower-level adapter. The game uses the explicit
    # equal-weight prepare_selected helper. Call at preparation, not per frame.
    def prepare(selection:, weights:, registry: GameRoomContent.registry)
      unless selection.is_a?(Hash) && !selection.empty? && selection.all? do |set_id, language|
          set_id.is_a?(String) && !set_id.empty? && language.is_a?(String) && !language.empty?
        end
        raise Unavailable, "Select at least one question set and its language"
      end
      unless weights.is_a?(Hash) && weights.keys.all? { |key| key.is_a?(String) } && weights.keys.sort == selection.keys.sort &&
          weights.values.all? { |weight| weight.is_a?(Integer) && weight.positive? }
        raise Unavailable, "Question-set weights must be specified for every selected set"
      end

      entries = selection.keys.sort.map do |set_id|
        language = selection.fetch(set_id)
        pack = registry.pack_for(game_id: "quiz", kind: "quiz", set_id: set_id, language_id: language)
        raise Unavailable, "Selected question set #{set_id}/#{language} is unavailable" unless pack

        questions = pack.data["questions"]
        unless questions.is_a?(Array) && !questions.empty? &&
            questions.all? { |question| valid_question?(question, registry.language(language)) } &&
            questions.map { |question| question["id"] }.uniq.length == questions.length
          raise Unavailable, "Selected question set #{set_id}/#{language} is empty or invalid"
        end
        { pack: pack, questions: questions, weight: weights.fetch(set_id) }.freeze
      end
      Prepared.new(entries)
    end

    def public_view(question)
      question.slice(*PUBLIC_FIELDS).to_h do |key, value|
        [key, value.is_a?(Array) ? value.map(&:dup) : value.is_a?(String) ? value.dup : value]
      end
    end

    def valid_question?(question, language)
      return false unless question.is_a?(Hash) && language
      return false unless %w[id prompt correct category].all? do |key|
        question[key].is_a?(String) && !question[key].strip.empty?
      end
      return false unless question["id"].length.between?(1, 32) && question["wrong"].is_a?(Array) && question["wrong"].length == 3

      answers = [question["correct"]] + question["wrong"]
      answers.all? { |answer| answer.is_a?(String) && !answer.strip.empty? } &&
        answers.map { |answer| language.normalize(answer).downcase }.uniq.length == 4
    end
    private_class_method :valid_question?

    class Prepared
      attr_reader :fingerprint, :selection, :weights

      def initialize(entries)
        @entries = entries.freeze
        @selection = entries.to_h { |entry| [entry[:pack].set_id, entry[:pack].language_id] }.freeze
        @weights = entries.to_h { |entry| [entry[:pack].set_id, entry[:weight]] }.freeze
        @weight_total = entries.sum { |entry| entry[:weight] }
        @fingerprint = Digest::SHA256.hexdigest(JSON.generate(entries.map do |entry|
          pack = entry[:pack]
          [pack.set_id, pack.language_id, pack.id, pack.version, pack.checksum, entry[:weight]]
        end)).freeze
        freeze
      end

      # This is the resolver's complete answer data, NOT a public event. The
      # race integration must publish only QuestionSets.public_view(result)
      # until the normal private-answer commit/reveal phase has resolved.
      def draw(seed:)
        raise ArgumentError, "Invalid question seed" unless seed.is_a?(Integer)

        random = Random.new(seed)
        draw = random.rand(@weight_total)
        entry = @entries.find { |candidate| (draw -= candidate[:weight]) < 0 }
        pack, questions = entry.values_at(:pack, :questions)
        question = questions.fetch(random.rand(questions.length))
        indexed_answers = [question.fetch("correct"), *question.fetch("wrong")].each_with_index.to_a
        shuffled = GameRoomRandom.shuffle(indexed_answers, random: random)
        {
          set_id: pack.set_id, pack_id: pack.id, pack_version: pack.version,
          pack_checksum: pack.checksum, language_id: pack.language_id,
          question_id: question.fetch("id"), category: question.fetch("category"),
          prompt: question.fetch("prompt"), choices: shuffled.map(&:first).freeze,
          correct_index: shuffled.index { |_answer, index| index.zero? }
        }.freeze
      end
    end
  end
end
