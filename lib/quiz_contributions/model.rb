# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require_relative '../game_content'
require_relative '../game_room_localization'

module GameRoomQuizContributions
  class Error < StandardError; end
  class Invalid < Error; end
  class Unavailable < Error; end

  module Model
    using GameRoomLocalization::Translations
    MAX_ITEMS = 1000
    MAX_BYTES = 16 * 1024 * 1024
    UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
    module_function

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def new_question(category = '')
      {'prompt' => '', 'choices' => ['', '', '', ''], 'correct_index' => 0,
        'category' => category, 'source' => '', 'note' => ''}
    end

    # Reorder only the editor's copy. Old drafts and delivery digests remain
    # unchanged until the user saves the edited question.
    def correct_first(value)
      result = copy(value)
      answer = result['choices'].delete_at(result['correct_index'])
      result['choices'].unshift(answer)
      result['correct_index'] = 0
      result
    end

    def new_draft(kind, target: {})
      {'id' => SecureRandom.uuid, 'kind' => kind, 'target' => copy(target),
        'title' => '', 'language' => '', 'description' => '', 'categories' => [],
        'items' => []}
    end

    def pack_target(pack)
      {'set_id' => pack.set_id, 'pack_id' => pack.id, 'pack_version' => pack.version,
        'pack_checksum' => pack.checksum, 'language_id' => pack.language_id, 'title' => pack.title}
    end

    def text!(value, maximum, required: true)
      raise Invalid, _('Invalid proposal.') unless value.nil? || value.is_a?(String)
      text = GameRoomContent.utf8(value).strip
      raise Invalid, _('Complete the required fields.') if required && text.empty?
      raise Invalid, _('This text is too long.') if text.length > maximum || !text.valid_encoding? || text.include?("\0")
      text
    end

    def question(value, complete: true)
      raise Invalid, _('Invalid question.') unless value.is_a?(Hash) && value['choices'].is_a?(Array) &&
        value['choices'].size == 4 && value['correct_index'].is_a?(Integer) && value['correct_index'].between?(0, 3)
      result = {'prompt' => text!(value['prompt'], 1500, required: complete),
        'choices' => value['choices'].map { |answer| text!(answer, 500, required: complete) },
        'correct_index' => value['correct_index'], 'category' => text!(value['category'], 120, required: complete),
        'source' => text!(value['source'], 1000, required: false), 'note' => text!(value['note'], 1000, required: false)}
      result
    end

    # Partial questions are valid drafts. Transport/recovery fields are not
    # content, and must not change the identity of a submitted proposal.
    def draft(value)
      raise Invalid, _('Invalid proposal.') unless value.is_a?(Hash) && UUID.match?(value['id'].to_s) &&
        %w[question set].include?(value['kind']) && value['target'].is_a?(Hash) &&
        value['items'].is_a?(Array) && value['items'].size <= MAX_ITEMS && value['categories'].is_a?(Array)
      result = {'id' => value['id'], 'kind' => value['kind'], 'target' => copy(value['target']),
        'title' => text!(value['title'], 120, required: false), 'language' => text!(value['language'], 35, required: false),
        'description' => text!(value['description'], 2000, required: false),
        'categories' => value['categories'].map { |s| text!(s, 120) }.uniq,
        'items' => value['items'].map { |q| question(q, complete: false) }}
      raise Invalid, _('This draft is too large.') if JSON.generate(result).bytesize > MAX_BYTES
      result
    end

    def title(value)
      value['kind'] == 'set' ? value['title'] : value.dig('target', 'title')
    end

    def language(value)
      value['kind'] == 'set' ? value['language'] : value.dig('target', 'language_id')
    end

    def categories(value)
      (value['categories'] + value['items'].map { |q| q['category'] }).reject(&:empty?).uniq
    end

    # Editorial correctness, repeated answers and repeated questions are for
    # the reviewer. Submission checks only required fields and safe limits.
    def completion_errors(value)
      data = draft(value)
      errors = []
      if data['kind'] == 'set'
        errors << _('Set: enter a title.') if data['title'].empty?
        errors << _('Set: enter a language code, for example pl or en.') unless GameRoomContent::LANGUAGE_ID_PATTERN.match?(data['language'])
      elsif !%w[set_id pack_id pack_version pack_checksum language_id title].all? { |key| !data['target'][key].to_s.empty? }
        errors << _('Choose a question set.')
      end
      errors << _('Add at least one question.') if data['items'].empty?
      data['items'].each_with_index do |q, i|
        missing = []
        missing << _('Enter the question.') if q['prompt'].empty?
        q['choices'].each_with_index do |answer, j|
          missing << GameRoomContent.utf8(_('Enter answer %{letter}.')) % {letter: ('A'.ord + j).chr} if answer.empty?
        end
        missing << _('Choose a category.') if q['category'].empty?
        missing.each do |message|
          errors << GameRoomContent.utf8(_('Question %{number}: %{error}')) % {number: i + 1, error: message}
        end
      end
      errors.map { |message| GameRoomContent.utf8(message) }
    end

    def packet(value, author:)
      data = draft(value)
      errors = completion_errors(data)
      raise Invalid, errors.join("\r\n") unless errors.empty?
      data['categories'] = categories(data)
      result = {'format' => 'power-games-quiz-proposal', 'version' => 1, 'author' => author.downcase, 'proposal' => data}
      result['submission_id'] = Digest::SHA256.hexdigest(JSON.generate(result))
      result
    end
  end
end
