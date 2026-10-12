require_relative 'client_helpers'

class DuckClientLocalTest
  include DuckClientTest

  def run
    private_types = ENGINE::REALTIME + ENGINE::SHARED
    kinds = GameRoomDuckRacing::Challenges::BY_ID.keys - private_types
    kinds &= ENGINE::SPEED_TYPES if ENV['DUCK_SPEED_ONLY'] == '1'
    kinds.each { |kind| private_attempt(kind) }
    deadlines_and_chat
    resource_failure
    actual_playback
    spectator
    description unless ENV['DUCK_SPEED_ONLY'] == '1'
    report('Duck local client attempts, readiness, deadlines, audio and private context')
  end

  def private_attempt(kind)
    setup_client(kind)
    trace = @client.instance_variable_get(:@trace)
    assert(trace, "No attempt for #{kind}")
    assert_equal(1, @game.loads)
    assert_equal(kind, @client.local_view[:type])
    assert_equal(0, @client.context_data['duck_seat'])
    assert_equal(true, @client.context_data['duck_host'])
    assert_equal(true, @client.context_data['duck_ready'])
    assert_equal(false, @client.local_view.key?(:answer))
    assert_equal(false, @client.local_view.key?(:results))
    assert_equal(false, @client.local_view.key?(:scores))
    12.times do |index|
      replace { |replay| replay.state[:round][:last_seen][1] += index + 1 }
      assert_equal(trace, @client.instance_variable_get(:@trace), "Foreign refresh restarted #{kind}")
      assert_equal(1, @game.loads)
    end

    prepared = ENGINE::SPEED_TYPES.include?(kind) && kind != 'count_ducks'
    finish_preparation if prepared
    offset = prepared ? @program.now_ms : 0
    model = trace.state[:model]
    case kind
    when 'rock_paper_scissors' then @surface.push(:choose, value: 'rock')
    when 'dice_duel', 'risky_dice' then @surface.push(:roll)
    when 'blackjack' then @surface.push(:stand)
    when 'guess_number', *GameRoomDuckRacing::NumericChallenges::ANSWER_TYPES
      @surface.push(:answer, value: model[:answer])
    when 'quiz'
      @surface.push(:answer, value: model[:question][:correct_index])
    end
    advance(offset + 500)
    if kind == 'risky_dice' && !trace.finished?
      @surface.push(:save)
      advance(600)
    end
    # Let the real local playback adapter acknowledge audio. No fake score
    # or direct playback_finished injection is used by this client test.
    if %w[count_ducks rhythm simon hit_duck].include?(kind)
      700.times do
        advance(@program.now_ms + 100)
        break if trace.finished?
        view = @client.local_view
        if kind == 'count_ducks' && view.dig(:own, :phase) == :responding
          @surface.push(:answer, value: model[:private][:players][0][:playback]&.[](:events)&.length || 100)
        elsif kind == 'rhythm' && view.dig(:own, :phase) == :ready
          @surface.push(:begin)
        elsif kind == 'simon' && view.dig(:own, :phase) == :responding
          @surface.push(:tone, value: 1)
          @surface.push(:tone, value: 2)
        end
      end
    end
    advance(80_000) unless trace.finished?
    assert(trace.finished?, "Attempt did not finish: #{kind}")
    pending = request
    assert_equal('submit_trace', pending['action'])
    assert_equal(trace.snapshot, pending['trace'])
    assert_equal(false, @surface.presentation[:enabled])
    assert_equal(false, pending.key?('score'))
    assert_equal(false, pending.key?('value'))
    snapshot = Marshal.dump(pending)
    pending['trace']['actions'].clear
    assert_equal(snapshot, Marshal.dump(request), 'Caller mutated the queued trace')
    5.times { @client.tick; assert_equal(snapshot, Marshal.dump(request)) }
    replace do |replay|
      if replay.state[:round][:attempts]
        replay.state[:round][:attempts][0] = ENGINE.result_for(trace.state, 0)
      else
        replay.state[:round][:private][:commitments][0] = 'accepted-commitment'
      end
      replay.state[:round][:last_seen][0] = 100_000 + @program.now_ms
    end
    assert_equal(nil, request, 'A received commitment did not acknowledge the trace')
    assert_equal(trace, @client.instance_variable_get(:@trace))
    @client.tick
    assert_equal(nil, request)
  ensure
    close
  end

  def deadlines_and_chat
    setup_client('copy_number')
    advance(0)
    trace = @client.instance_variable_get(:@trace)
    answer = trace.state[:model][:answer]
    @surface.active = false
    @surface.push(:answer, value: answer)
    advance(300)
    assert_equal(false, trace.finished?, 'Chat Enter answered the challenge')
    assert_equal(0, @surface.reads)
    @surface.active = true
    advance(600)
    assert_equal(false, trace.finished?, 'Stale chat input survived returning')
    advance(ENGINE::PREPARATION_DELAY_MS)
    advance(ENGINE::PREPARATION_MS)
    @progress.covered = true
    @surface.push(:answer, value: answer)
    advance(ENGINE::PREPARATION_MS + 14_999, background: true)
    assert_equal(false, trace.finished?)
    advance(ENGINE::PREPARATION_MS + 15_000, background: true)
    assert(trace.finished?, 'Covered challenge did not expire without a key')
    assert_equal([], request['trace']['actions'])
    assert_equal(15_000, request['trace']['finished_at'])
    assert_equal(false, @client.local_view[:finished], 'Local deadline declared the whole challenge finished')
    assert_equal({0 => true, 1 => false}, @client.local_view[:ready], 'A local deadline invented another person\'s result')
    assert_equal(nil, @client.local_view[:answer])
    @progress.covered = false
    @client.tick
    assert_equal(false, @surface.presentation[:enabled])
    assert_equal(1, @game.loads)
  ensure
    close
  end

  def resource_failure
    setup_client('dice_duel', phase: :preparing)
    assert_equal(true, @client.context_data['duck_ready'])
    assert_equal(nil, @client.local_view)
    assert_equal(nil, @client.instance_variable_get(:@trace))
    @game.resources = resources.merge(fingerprint: 'b' * 64)
    replace do |replay|
      replay.state[:round][:challenge][:id] = 2
      replay.state[:race][:challenge][:id] = 2
    end
    assert_equal(false, @client.context_data['duck_ready'])
    assert_equal('cancel', request['action'])
    assert_equal('technical', request['reason'])
    spoken = $spoken_messages.length
    5.times { replace; @client.tick }
    assert_equal(spoken, $spoken_messages.length)
    assert_equal(2, @game.loads)
    assert_equal(nil, @client.instance_variable_get(:@trace))
    close
    setup_client('copy_number')
    finish_preparation
    @surface.push(:answer, value: @client.instance_variable_get(:@trace).state[:model][:answer])
    advance(@program.now_ms + 100)
    @client.automatic_error(:local_storage_unavailable)
    assert_equal('cancel', request['action'])
    @client.tick
    assert_equal('cancel', request['action'], 'A failed write fabricated a completed score')
  ensure
    close
  end

  def actual_playback
    setup_client('simon')
    trace = @client.instance_variable_get(:@trace)
    @program.missing = true
    advance(0)
    assert_equal('cancel', request['action'])
    assert_equal('technical', request['reason'])
    assert_equal(false, trace.finished?)
    assert(@audios.first.error)
    assert_equal(nil, @client.surface_spec(@replay, @viewer))
    count = $spoken_messages.length
    10.times { |index| advance(index * 100) }
    assert_equal(count, $spoken_messages.length)
    close
    setup_client('count_ducks')
    output = GameRoomSoundOutput.new(@program, audio_game: true, covered: -> { true })
    @program.class.settings = {'background_game_sounds' => 'all'}
    160.times { |index| advance(index * 100) }
    assert_equal(:responding, @client.local_view.dig(:own, :phase))
    assert(@program.events.length >= 5)
    assert(@program.events.all? { |event| event[:volume].zero? })
    assert_equal(nil, request)
    assert_equal(false, @client.instance_variable_get(:@trace).finished?)
  ensure
    output&.close
    @program.class.settings = {}
    close
  end

  def spectator
    setup_client('count_ducks', viewer: 'Charlie')
    assert_equal(false, @client.context_data['duck_ready'])
    assert_equal(false, @client.context_data['duck_host'])
    assert_equal(2, @client.context_data['duck_seat'])
    assert_equal(nil, @client.instance_variable_get(:@trace))
    assert_equal(nil, @client.local_view[:own])
    assert_equal(false, @surface.presentation[:enabled])
    advance(60_000)
    assert_equal(nil, request)
    assert_equal([], @program.sounds)
    close
    setup_client('dice_duel', viewer: 'Outside')
    assert_equal(nil, @client.context_data['duck_seat'])
    assert_equal(false, @surface.presentation[:enabled])
    assert(@client.action({'kind' => 'duck', 'action' => 'describe', 'card_id' => 1}, @replay, @viewer))
    assert_equal(nil, request)
  ensure
    close
  end

  def description
    setup_client('dice_duel')
    card = @replay.state[:race][:racers][0][:hand].first
    count = $spoken_messages.length
    assert(@client.action({'kind' => 'duck', 'action' => 'describe', 'card_id' => card.id}, @replay, @viewer))
    assert_equal("Description of #{card.type}", $spoken_messages.last)
    assert(@client.action({'kind' => 'duck', 'action' => 'describe', 'card_id' => -1}, @replay, @viewer))
    assert_equal(count + 1, $spoken_messages.length)
    assert_equal(false, @client.action({'kind' => 'duck', 'action' => 'race'}, @replay, @viewer))
    assert_equal(nil, request)
  ensure
    close
  end
end

DuckClientLocalTest.new.run
