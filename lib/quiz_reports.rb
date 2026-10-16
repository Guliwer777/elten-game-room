# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'quiz_contributions/repository'
require_relative 'quiz_contributions/views'

# Deliberately ephemeral: no drafts, resources, tables or files. The table
# owns the tracker; only the review opened after leaving can access the network.
module GameRoomQuizReports
  class Tracker
    using GameRoomLocalization::Translations
    attr_reader :user

    def initialize(user:, current_user:)
      @user, @current_user = user.to_s.downcase, current_user
      @marked = {}
    end

    def active?
      !@user.empty? && @current_user.call.to_s.downcase == @user
    end

    def observe(session, question)
      return unless active?
      if @session != session
        @session, @current, @previous = session, nil, nil
      end
      return unless question
      identity = [session, question['round'], question['position'], question['id']]
      return if @current && @current[0] == identity
      @previous = @current
      @current = [identity, JSON.parse(JSON.generate(question))]
    end

    def shortcuts
      [[[], 'current', _('Mark the current question for reporting')],
        [[:shift], 'previous', _('Mark the previous question for reporting')]].map do |modifiers, name, label|
        GameRoomGames::GameShortcut.new(key: 'b', modifiers: [:control] + modifiers,
          kind: :action, label: label, action_kind: 'question_report', action_name: name)
      end
    end

    def mark(which)
      return _('The signed-in account has changed.') unless active?
      entry = which == 'previous' ? @previous : @current
      return _('There is no previous question to mark.') if !entry && which == 'previous'
      return _('There is no question to mark yet.') unless entry
      question = entry[1]
      key = question.values_at('language', 'set', 'id', 'prompt', 'correct')
      return _('This question is already marked.') if @marked.key?(key)
      @marked[key] = question
      _('Question marked.')
    end

    def questions
      active? ? @marked.values : []
    end

    def empty?; questions.empty?; end
  end

  class Delivery
    using GameRoomLocalization::Translations
    RECIPIENT = 'papierek'

    def initialize(repository, messages: nil)
      @repository, @messages = repository, messages || EltenLink::Messages
    end

    def packet(question, problem)
      {'id' => SecureRandom.uuid, 'question' => question, 'problem' => problem, 'confirmed' => false}
    end

    def subject(packet)
      "Power Games: Quiz question report [#{packet.fetch('id')}]"
    end

    def body(packet)
      q = packet.fetch('question')
      [q.fetch('prompt'), *q.fetch('answers').each_with_index.map { |answer, i| "#{('A'.ord + i).chr}. #{answer}" },
        '', packet.fetch('problem'), '', "Set: #{q['set']}; language: #{q['language']}; question: #{q['id']}",
        "Category: #{q['category']}", "Answer in the set: #{q['correct']}",
        "Power-Games-Question-Report: #{packet.fetch('id')}"].join("\r\n")
    end

    def matching_messages(packet, token)
      response = @messages.messages(@repository.request_client(token), user: RECIPIENT,
        subject: subject(packet), limit: 10)
      @repository.check(token)
      unless response.respond_to?(:messages) && response.respond_to?(:more) && !response.more
        raise GameRoomQuizContributions::Unavailable, _('The report delivery status could not be checked. Try again.')
      end
      response.messages.select do |message|
        message.sender.to_s.casecmp?(@repository.user) && message.receiver.to_s.casecmp?(RECIPIENT) &&
          message.subject == subject(packet) &&
          message.text.to_s.include?("Power-Games-Question-Report: #{packet.fetch('id')}")
      end
    end

    def send_and_clean(packet, token: nil)
      @repository.check(token)
      unless packet['confirmed']
        if matching_messages(packet, token).empty?
          sent = @messages.send_text(@repository.request_client(token), to: RECIPIENT,
            subject: subject(packet), text: body(packet))
          unless sent == true
            raise GameRoomQuizContributions::Unavailable, _('Sending the report was not confirmed. Try again to check its status.')
          end
        end
        # Record confirmation in memory before any cleanup. An explicit retry
        # can then retry deletion without sending another copy.
        packet['confirmed'] = true
      end
      @repository.check(token)
      return true if @repository.user.casecmp?(RECIPIENT)

      matching_messages(packet, token).each do |message|
        raise GameRoomQuizContributions::Unavailable, _('The sent message could not be removed.') unless message.id.to_i.positive?
        @messages.delete_message(@repository.request_client(token), message.id)
        @repository.check(token)
      end
      true
    end
  end

  class Views < GameRoomQuizContributions::Views
    using GameRoomLocalization::Translations

    def report(question, problem, locked: false)
      description = [question['prompt'], *question['answers'].each_with_index.map { |answer, i| "#{('A'.ord + i).chr}. #{answer}" },
        text(_('Correct answer: %{answer}')) % {answer: question['correct']}].join("\r\n")
      question_field = GameRoomUI::HelpText.new(text(_('Question')), text: text(description),
        type: EditBox::Flags::MultiLine | EditBox::Flags::ReadOnly, quiet: true)
      problem_field = EditBox.new(text(_('What is wrong with this question?')), text: text(problem),
        type: EditBox::Flags::MultiLine | (locked ? EditBox::Flags::ReadOnly : 0), quiet: true)
      send_button, cancel = Button.new(text(_('Send'))), Button.new(text(_('Skip this question')))
      form = GameRoomUI::Form.new([question_field, problem_field, send_button, cancel], program: @program, quiet: true)
      form.cancel_button = cancel
      action = :skip
      send_button.on(:press) do
        if problem_field.text.to_s.strip.empty?
          alert(_('Describe the problem before sending.'))
          form.index = 1
          problem_field.focus
        else
          action = :send
          form.resume
        end
      end
      cancel.on(:press) { form.resume }
      form.wait
      [action, problem_field.text.to_s]
    end
  end

  class Review
    using GameRoomLocalization::Translations

    def initialize(program, tracker, views: nil, delivery: nil)
      @program, @tracker, @delivery = program, tracker, delivery
      @views = views || Views.new(program)
    end

    def run
      return if @tracker.empty?
      return unless @views.confirm(_('You marked questions during the game. Would you like to report them?'))
      return unless @tracker.active?
      unless @delivery
        repository = GameRoomQuizContributions::Repository.new(app_uuid: @program.class.server_app_uuid,
          user: @tracker.user, current_user: -> { Session.name })
        @delivery = Delivery.new(repository)
      end
      @tracker.questions.each do |question|
        return unless @tracker.active?
        problem, packet = '', nil
        loop do
          action, problem = @views.report(question, problem, locked: !packet.nil?)
          break unless action == :send
          return unless @tracker.active?
          packet ||= @delivery.packet(question, problem)
          if deliver(packet)
            @views.notice(_('Sent to the author.'), title: _('Question report'))
            break
          end
        end
      end
    end

    private

    def deliver(packet)
      EltenAPI::Tasks.run(title: GameRoomContent.utf8(_('Sending question report')), cancellable: true, show_after: 0.5) do |_progress, token|
        @delivery.send_and_clean(packet, token: token)
      end
    rescue EltenAPI::Tasks::Cancelled, EltenAPI::Tasks::TimedOut, EltenLink::Error, IOError, SystemCallError, GameRoomQuizContributions::Error
      message = if packet['confirmed']
        _('The report was sent, but its copy could not be removed from your sent messages. Retry to remove it without sending the report again.')
      else
        _('Sending the report could not be confirmed. Retry to check whether it arrived. Your description remains in this form.')
      end
      @views.notice(message, title: _('Question report'))
      false
    end
  end
end
