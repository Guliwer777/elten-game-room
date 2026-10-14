# frozen_string_literal: true

require 'tmpdir'
require 'zip'
require_relative 'repository'

module GameRoomQuizContributions
  class Delivery
    using GameRoomLocalization::Translations
    RECIPIENT = 'papierek'
    MAX_ATTACHMENT = 4 * 1024 * 1024

    def initialize(repository, messages: nil)
      @repository, @messages = repository, messages || EltenLink::Messages
    end

    def subject(packet)
      "Power Games: #{Model.title(packet['proposal'])} [#{packet.fetch('submission_id')}]"
    end

    def filename(packet)
      "power-games-questions-#{packet.fetch('submission_id')}.zip"
    end

    def delivered?(packet, token: nil)
      !matching_messages(packet, token: token).empty?
    end

    # This operation affects the signed-in sender's mailbox only. Never
    # delete self-addressed submissions: that is also the author's inbox.
    def remove_sender_copy(packet, token: nil)
      return true if @repository.user.casecmp?(RECIPIENT)
      matching_messages(packet, token: token).each do |message|
        @repository.check(token)
        raise Unavailable, _('The sent message could not be removed.') unless message.id.to_i.positive?
        @messages.delete_message(@repository.request_client(token), message.id)
        @repository.check(token)
      end
      true
    end

    def matching_messages(packet, token: nil)
      response = @messages.messages(@repository.request_client(token), user: RECIPIENT, subject: subject(packet), limit: 10)
      @repository.check(token)
      raise Unavailable, _('The delivery status could not be checked. Your draft has been kept.') unless response.respond_to?(:messages) && response.respond_to?(:more)
      matches = response.messages.select do |message|
        message.sender.to_s.casecmp?(@repository.user) && message.receiver.to_s.casecmp?(RECIPIENT) &&
          message.subject == subject(packet) && message.text.to_s.include?("Power-Games-Submission: #{packet['submission_id']}") &&
          message.attachments.to_a.size == 1 && message.attachments_names.to_a == [filename(packet)]
      end
      raise Unavailable, _('The delivery status could not be checked. Your draft has been kept.') if response.more
      matches
    end

    # There is no native message idempotency key. Check before an explicit
    # retry, and never automatically resend after an uncertain response.
    def send(packet, token: nil)
      return true if delivered?(packet, token: token)
      Dir.mktmpdir('power-games-questions-') do |directory|
        path = File.join(directory, filename(packet))
        Zip::File.open(path, create: true) do |zip|
          zip.get_output_stream('questions.json') { |io| io.write(JSON.pretty_generate(packet)) }
          zip.get_output_stream('questions.txt') { |io| io.write(readable(packet)) }
        end
        raise Invalid, _('The attachment exceeds 4 MB. Split the proposal into smaller drafts.') if File.size(path) > MAX_ATTACHMENT
        @repository.check(token)
        result = @messages.send_text(@repository.request_client(token), to: RECIPIENT,
          subject: subject(packet), text: body(packet), attachments: [path])
        @repository.check(token)
        raise Unavailable, _('Sending was not confirmed. Your draft has been kept; retrying will check for the previous message first.') unless result == true
      end
      true
    end

    def body(packet)
      data = packet.fetch('proposal')
      [text(_('Quiz proposal: %{title}')) % {title: Model.title(data)},
        data['kind'] == 'set' ? text(_('New question set')) : text(_('Questions for an existing set')),
        text(_('Language: %{language}')) % {language: Model.language(data)},
        text(_('Questions: %{count}')) % {count: data['items'].size},
        text(_('Categories: %{categories}')) % {categories: data['categories'].join(', ')},
        data['description'], text(_('The attachment contains the questions in TXT and JSON for review.')),
        "Power-Games-Submission: #{packet['submission_id']}"].reject(&:empty?).join("\r\n")
    end

    def readable(packet)
      lines = [body(packet), '']
      packet['proposal']['items'].each_with_index do |q, index|
        lines += [(index + 1).to_s, q['prompt'], *q['choices'].each_with_index.map { |answer, i| "#{('A'.ord + i).chr}. #{answer}" },
          text(_('Correct answer: %{answer}')) % {answer: ('A'.ord + q['correct_index']).chr},
          text(_('Category: %{category}')) % {category: q['category']}]
        lines << text(_('Source: %{source}')) % {source: q['source']} unless q['source'].empty?
        lines << text(_('Editorial note: %{note}')) % {note: q['note']} unless q['note'].empty?
        lines << ''
      end
      lines.join("\r\n")
    end

    private

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
