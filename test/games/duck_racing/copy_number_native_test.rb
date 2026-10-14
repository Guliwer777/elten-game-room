require_relative '../../support/duck_challenge_native'

# Real EditBox/Form/KeyboardState; the fixture supplies OS character batches
# and clipboard contents. No answer is injected into a game model.
module Clipboard
  class << self
    attr_accessor :text
  end
end

module SpeechOutput
  def self.list; []; end
end

class DuckCopyNumberNativeTest
  include DuckChallengeTest

  def run
    @driver = DuckChallengeNativeDriver.new
    digit_completion
    fast_batch_and_enter
    paste_and_length
    repeated_wrong_answers
    drafts_and_reuse
    guarded_input
    focus_chat_and_cover
    other_number_fields
    puts 'PASS native numeric completion: all five numeric challenges, digit widths, zero, retries, paste, Enter deduplication, drafts/reuse, guards, focus isolation and count playback'
  ensure
    @surface&.deactivate_input
    $activecontrols = []
  end

  def setup(kind = 'copy_number', state: nil, view: nil, seed: 7)
    @surface&.deactivate_input
    @model = challenge_state(kind, seed: seed)
    spec = GameSurfaces::DuckChallengeSpec.new(challenge_id: "native-#{kind}", kind: kind,
      viewer: 0, view: view || ENGINE.view(@model, seat: 0))
    @surface = GameSurfaces.build(spec, state: state || {})
    @form = @driver.form(@surface)
    @field = @surface.fields.first
    @number = (kind == 'count_ducks' ? @model.dig(:model, :private, :count) : @model.dig(:model, :answer)).to_s
    @at = 1
  end

  def frame(characters = '', events: nil, form: @form)
    events ||= characters.empty? ? [] : @driver.tap(characters.getbyte(0))
    @driver.frame(form, events, characters: characters)
  end

  def take
    @surface.take_input(@form)
  end

  def enter
    frame(events: @driver.tap(0x0D))
    take
  end

  def apply(input)
    @at += 10
    assert(ENGINE.submit(@model, seat: 0, action: input, now_ms: @at, resources: challenge_resources))
    @surface.present(ENGINE.view(@model, seat: 0))
  end

  def digit_completion
    setup
    @number.chars.each_with_index do |digit, index|
      frame(digit)
      inputs = take
      if index < @number.length - 1
        assert_equal([], inputs, 'A partial number was submitted')
      else
        assert_equal([{kind: :answer, value: @number, press_id: 1}], inputs,
          'Completing the shown number did not submit it automatically')
        apply(inputs.first)
      end
    end
    assert_equal([], enter, 'Enter sent an already completed answer again')
    assert_equal(1, @model[:model][:players][0][:attempts].length)
    assert_equal(false, @surface.presentation[:enabled])
  end

  def fast_batch_and_enter
    setup
    frame(@number, events: @number.chars.flat_map { |digit| @driver.tap(digit.ord) } + @driver.tap(0x0D))
    assert_equal([{kind: :answer, value: @number, press_id: 1}], take,
      'Same-frame characters and Enter submitted twice or lost the answer')
    assert_equal([], enter, 'Fresh Enter repeated an unedited submission')
    @driver.frame(@form, [[0x0D, :repeat]], held: [0x0D])
    assert_equal([], take, 'Held Enter repeated automatic submission')
  end

  def paste_and_length
    setup
    assert_equal(@number.length, @field.max_length)
    Clipboard.text = @number
    @field.paste
    frame
    assert_equal([{kind: :answer, value: @number, press_id: 1}], take, 'Native paste was not submitted')
    assert_equal([], enter)

    setup
    Clipboard.text = @number + '0'
    @field.paste
    frame
    assert_equal('', @field.text, 'An overlong paste was silently truncated')
    assert_equal([], take, 'An overlong paste submitted an unintended number')
    frame('x' * @number.length)
    assert_equal([], take, 'Non-digits triggered automatic submission')

    # The threshold follows the public prompt, not the model's three-digit
    # generator or a hard-coded constant in the surface.
    view = ENGINE.view(challenge_state('copy_number'), seat: 0)
    view[:question][:number] = 12_345
    setup(view: view)
    assert_equal(5, @field.max_length)
    frame('1234')
    assert_equal([], take)
    frame('5')
    assert_equal('12345', take.first[:value])
  end

  def repeated_wrong_answers
    setup
    wrong = @number == '111' ? '222' : '111'
    2.times do |attempt|
      frame(wrong)
      inputs = take
      assert_equal([{kind: :answer, value: wrong, press_id: attempt + 1}], inputs,
        'Replacing the selected draft with the identical wrong number was lost')
      apply(inputs.first)
      assert_equal(attempt + 1, @model[:model][:players][0][:attempts].length)
      assert_equal([0, wrong.length], [@field.index, @field.check], 'Retry did not select the old draft')
      2.times do
        frame
        @surface.present(ENGINE.view(@model, seat: 0))
        assert_equal([], take, 'A refresh repeated the wrong answer')
      end
      assert_equal([], enter, 'Enter spent another attempt without editing')
    end
    frame(@number)
    correct = take
    assert_equal(3, correct.first[:press_id])
    apply(correct.first)
    assert_equal(:correct, @model[:model][:players][0][:status])
  end

  def drafts_and_reuse
    setup
    @field.set_text(@number)
    frame
    assert_equal([], take, 'Programmatic set_text submitted a saved draft')
    draft = @surface.state
    setup(state: draft)
    2.times { frame; assert_equal([], take, 'A restored draft submitted itself') }
    original = @field
    @surface.update_spec(GameSurfaces::DuckChallengeSpec.new(**@surface.spec.to_h.merge(view: ENGINE.view(@model, seat: 0))))
    assert_equal(original, @surface.fields.first)
    frame
    assert_equal([], take, 'Reusing the control submitted a saved draft')
    assert_equal(@number, enter.first[:value], 'An explicit Enter could not submit the untouched saved draft')
    sent = @surface.state
    setup(state: sent)
    frame
    assert_equal([], take, 'Reload resent the previous answer')
    assert_equal([], enter, 'Reload forgot the submitted draft generation')
    @field.restore_selection(index: 0, check: @field.text.length)
    frame(@number)
    assert_equal(@number, take.first[:value], 'A fresh edit after reload was suppressed')
  end

  def guarded_input
    setup
    @surface.action_guard = -> { false }
    frame(@number)
    assert_equal([], take, 'Automatic submission bypassed the action guard')
    @surface.action_guard = nil
    frame
    assert_equal([], take, 'An input refused by the guard was deferred')
    assert_equal(@number, enter.first[:value], 'A fresh Enter after the guard was not allowed')

    setup
    frame(@number)
    @surface.action_guard = -> { false }
    assert_equal([], take, 'An already queued answer bypassed a newer guard')
    @surface.action_guard = nil
    frame
    assert_equal([], take, 'A rejected queued answer was replayed')
    assert_equal(@number, enter.first[:value])
  end

  def focus_chat_and_cover
    setup
    prefix = @number[0...-1]
    frame(prefix)
    assert_equal([], take)
    frame(events: @driver.tap(0x09))
    chat = @form.fields.last
    assert_equal(chat, @form.fields[@form.index])
    draft = chat.text.dup
    frame(@number)
    assert_equal([], take, 'Chat characters submitted a challenge answer')
    assert(chat.text.include?(@number))
    frame(events: @driver.tap(0x09, modifiers: [0x10]))
    assert_equal(prefix, @field.text)
    assert_equal([], take, 'Returning from chat submitted a partial number')

    foreign = GameRoomUI::Form.new([EditBox.new('Other window', text: '')], quiet: true)
    frame(@number, form: foreign)
    assert_equal([], take, 'A covered form consumed foreign text')
    assert_equal(prefix, @field.text)
    @field.focus
    frame
    assert_equal([], take, 'Returning from a covered form submitted a draft')
    frame(@number[-1])
    assert_equal(@number, take.first[:value])
    assert(chat.text.include?(@number) && chat.text.include?(draft))
  end

  def other_number_fields
    %w[guess_number arithmetic race_question count_ducks].each do |kind|
      widths = {}
      (1..120).each do |seed|
        model = challenge_state(kind, seed: seed)
        value = kind == 'count_ducks' ? model.dig(:model, :private, :count) : model.dig(:model, :answer)
        widths[value.to_s.length] ||= seed
        widths[:zero] = seed if value.zero?
      end
      assert(widths.key?(:zero), 'Arithmetic zero fixture missing') if kind == 'arithmetic'
      widths.each_value do |seed|
        setup(kind, seed: seed)
        if kind == 'count_ducks'
          frame(@number)
          assert_equal([], take, 'Count submitted during playback')
          acknowledge_challenge(@model)
          @surface.present(ENGINE.view(@model, seat: 0))
          frame
          assert_equal([], take, 'Playback completion submitted an old draft')
          @field.restore_selection(index: 0, check: @field.text.length)
        end
        view = ENGINE.view(@model, seat: 0)
        assert_equal(@number.length, view[:answer_digits])
        assert(!view.key?(:answer), 'The public hint exposed the answer')
        assert_equal(@number.length, @field.max_length)
        assert(@surface.presentation[:header].include?("Answer: #{@number.length}"))
        @number.chars.each_with_index do |digit, index|
          frame(digit)
          inputs = take
          if index < @number.length - 1
            assert_equal([], inputs, "#{kind} submitted a prefix")
          else
            expected = kind == 'count_ducks' ? @number.to_i : @number
            assert_equal([{kind: :answer, value: expected, press_id: 1}], inputs, "#{kind} still needs Enter")
            apply(inputs.first)
          end
        end
        assert_equal([], enter, "#{kind} sent the automatic answer again")
        assert(ENGINE.own_finished?(@model, 0))
      end

      # A fresh native edit is a new attempt, even if it repeats the same
      # wrong number. Merely pressing Enter must not spend another attempt.
      setup(kind)
      if kind == 'count_ducks'
        acknowledge_challenge(@model)
        @surface.present(ENGINE.view(@model, seat: 0))
      end
      wrong = @number == '1' * @number.length ? '2' * @number.length : '1' * @number.length
      frame(wrong)
      apply(take.fetch(0))
      assert_equal([], enter)
      if kind == 'count_ducks'
        frame(events: @driver.tap(0x74))
        assert_equal(:replay, take.fetch(0)[:kind], 'Numeric deduplication blocked F5')
      end
      frame(wrong)
      assert_equal(wrong.to_i, take.fetch(0)[:value].to_i, "#{kind} lost a repeated attempt")
    end
  end
end

DuckCopyNumberNativeTest.new.run
