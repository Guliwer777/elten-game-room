require_relative 'client_helpers'

class DuckClientAnnouncementsTest
  include DuckClientTest

  def run
    blackjack unless ENV['DUCK_MEMORY_ONLY'] == '1'
    guess_number unless ENV['DUCK_MEMORY_ONLY'] == '1'
    memory
    report('Duck client short speech: actual model inputs, refresh deduplication and complete fields')
  end

  def no_refresh_speech
    previous = $spoken_messages.dup
    5.times do |index|
      replace { |replay| replay.state[:round][:last_seen][1] += index + 1 }
      advance(@program.now_ms + 1)
    end
    assert_equal(previous, $spoken_messages, 'An unrelated refresh repeated challenge speech')
  end

  def blackjack
    seed = (0...100).find do |candidate|
      model = ENGINE.start(make_replay('blackjack', seed: candidate).state[:round][:challenge], resources: resources)
      ENGINE.current_turn(model) == 0 && model[:model][:players][0][:total] < 11
    end
    assert(seed, 'No fixture seed with room to draw')
    setup_client('blackjack', seed: seed)
    $spoken_messages.clear
    old_cards = @client.local_view[:own][:card_ranks]
    @surface.push(:hit)
    advance(500)
    input = request.fetch('input')
    replace { |replay| assert(ENGINE.submit(replay.state[:round][:engine], seat: 0, action: input, now_ms: 500, resources: resources)) }
    advance(501)
    own = @client.local_view[:own]
    assert_equal(old_cards.length + 1, own[:card_ranks].length)
    assert_equal([], $spoken_messages, 'The client duplicated public draw history')
    full = own[:card_ranks].map { |rank| GameRoomDuckRacing::ChallengePresentation.card_rank(rank) }.join(', ')
    assert(@surface.presentation[:header].include?("Cards: #{full}."))
    no_refresh_speech
    @surface.push(:stand)
    advance(600)
    input = request.fetch('input')
    replace { |replay| assert(ENGINE.submit(replay.state[:round][:engine], seat: 0, action: input, now_ms: 600, resources: resources)) }
    advance(601)
    assert_equal([], $spoken_messages, 'Standing duplicated the public history or announced an extra turn')
    assert(@surface.presentation[:header].include?("Cards: #{full}."), 'Standing erased the inspectable hand')
    no_refresh_speech
    replace { |replay| assert(ENGINE.submit(replay.state[:round][:engine], seat: 1,
      action: {kind: :stand, press_id: 1}, now_ms: 650, resources: resources)) }
    advance(650)
    assert_equal([], $spoken_messages, 'A completed public round produced private speech')
  ensure
    close
  end

  def guess_number
    setup_client('guess_number')
    answer = @client.instance_variable_get(:@trace).state[:model][:answer]
    guess = answer == 1 ? 2 : 1
    hint = answer == 1 ? 'The number is lower.' : 'The number is higher.'
    $spoken_messages.clear
    @surface.push(:answer, value: guess.to_s)
    advance(100)
    assert_equal(["#{hint} 9 attempts left."], $spoken_messages)
    @surface.push(:answer, value: guess.to_s)
    advance(200)
    assert_equal("#{hint} 8 attempts left.", $spoken_messages.last)
    previous = $spoken_messages.dup
    @surface.push(:answer, value: 'invalid')
    advance(400)
    assert_equal(previous, $spoken_messages, 'Invalid numeric input changed attempt feedback')
    assert(@surface.presentation[:header].include?(hint))
    assert(@surface.presentation[:header].include?('8 attempts left.'))
    no_refresh_speech
    previous = $spoken_messages.dup
    @surface.active = false
    @surface.push(:answer, value: answer.to_s)
    advance(600)
    assert_equal(previous, $spoken_messages, 'Typing in chat emitted challenge feedback')
    assert_equal(2, @client.local_view[:own][:attempts].length, 'Typing in chat submitted an answer')
  ensure
    close
  end

  def memory
    setup_client('sound_memory')
    $spoken_messages.clear
    pair = @replay.state[:round][:engine][:model][:private][:pairs].each_with_index.group_by(&:first).values.first.map(&:last)
    pair.each_with_index do |index, press|
      replace do |replay|
        engine = replay.state[:round][:engine]
        assert(ENGINE.submit(engine, seat: engine[:model][:public][:turn],
          action: {kind: :reveal, value: index == 9 ? 0 : index + 1, press_id: press + 1},
          now_ms: 100 + press, resources: resources))
      end
      advance(100 + press)
    end
    positions = pair.map { |index| index == 9 ? 0 : index + 1 }
    assert_equal([], $spoken_messages, 'Snapshot refresh must not overtake the shared memory feedback/turn sequence')
    assert(@surface.presentation[:header].include?("Matched positions: #{positions.join(', ')}."))
    no_refresh_speech
  ensure
    close
  end
end

DuckClientAnnouncementsTest.new.run
