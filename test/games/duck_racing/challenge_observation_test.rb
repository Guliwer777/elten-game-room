# frozen_string_literal: true

require_relative 'client_helpers'

class DuckChallengeObservationTest
  include DuckClientTest

  def run
    @results = []
    %w[Charlie Watcher].each do |viewer|
      check("#{viewer}: permitted fields and reminders for every non-realtime challenge") { fields(viewer) }
      check("#{viewer}: public question and committed-choice progress without answers") { progress(viewer) }
      check("#{viewer}: live duck sounds once, no countdown or actions") { live_ducks(viewer) }
      check("#{viewer}: cold snapshots never replay duck sounds") { cold_ducks(viewer) }
      check("#{viewer}: observer sound failure cannot cancel another player's challenge") { failed_ducks(viewer) }
      check("#{viewer}: stale starts, cancellation and a newer challenge") { lifecycle(viewer) }
      check("#{viewer}: muted observation keeps progressing without a return backlog") { muted_ducks(viewer) }
    end
    puts JSON.pretty_generate(checks: @checks, scenarios: @results)
    raise 'Duck observation regression failed' unless @results.all? { |row| row[:status] == 'PASS' }
  end

  def check(name)
    yield
    @results << {name: name, status: 'PASS'}
  rescue StandardError => error
    @results << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(4)}
  ensure
    close
  end

  def speech
    $spoken_messages.dup
  end

  def fields(viewer)
    kinds = GameRoomDuckRacing::Challenges::BY_ID.keys - ENGINE::REALTIME
    kinds.each do |kind|
      $spoken_messages.clear
      setup_client(kind, viewer: viewer)
      view = @client.local_view
      projection = @surface.presentation
      assert_equal(false, projection[:enabled], "#{kind}: spectator controls enabled")
      assert_equal('', projection[:instruction], "#{kind}: player instructions exposed")
      assert_equal(nil, projection[:auto_submit_length], "#{kind}: spectator answer field")
      reminder = GameRoomDuckRacing::ChallengePresentation.reminder(kind, view)
      assert(!reminder.match?(/Press|F5|Enter|Shift|attempt|digits|higher|lower/i), "#{kind}: control/hint reminder: #{reminder}")
      if kind == 'copy_number'
        assert(!projection[:header].include?('Number:'), 'Copy task leaked its initial number')
        assert(!reminder.include?('Number:'), 'P leaked the copy task number')
        assert(!view.key?(:question), 'The observer surface retained the hidden prompt')
      end
      assert(!view.key?(:public), "#{kind}: observer retained private event/arrangement fields") if %w[rhythm sound_order simon hit_duck].include?(kind)
      @surface.push(:answer, value: 2)
      advance(50)
      assert_equal(nil, request, "#{kind}: observer produced a durable action")
      close
    end
  end

  def progress(viewer)
    %w[arithmetic race_question quiz rock_paper_scissors].each do |kind|
      $spoken_messages.clear
      setup_client(kind, viewer: viewer)
      view = @client.local_view
      if %w[arithmetic race_question quiz].include?(kind)
        prompt = GameRoomDuckRacing::ChallengePresentation.prompt(kind, view)
        assert(speech.any? { |text| text.include?(prompt) }, "#{kind}: public question was not announced")
      end
      if %w[quiz rock_paper_scissors].include?(kind)
        $spoken_messages.clear
        replace { |replay| replay.state[:round][:private][:commitments][0] = 'committed-choice' }
        assert_equal(['Already chosen: Alice.'], speech, "#{kind}: committed choice was not announced once")
        assert_equal(nil, @client.local_view[:own_answer])
        assert_equal(nil, @client.local_view[:answers])
        $spoken_messages.clear
        3.times { replace }
        assert_equal([], speech, "#{kind}: refresh repeated commitment")
      end
      close
    end
  end

  def begin_ducks(viewer, id: 1, reset: true)
    setup_client('count_ducks', viewer: viewer, phase: :preparing, id: id) if reset
    before = @replay
    @replay = make_replay('count_ducks', id: id)
    @replay.state[:revision] = before.state[:revision] + 1
    @replay.state[:round][:started_at] += @program.now_ms
    @client.event(nil, before, @replay, viewer, Repository.new)
    @client.before_wait(@replay, viewer)
    attach
    before
  end

  def live_ducks(viewer)
    before = begin_ducks(viewer)
    model = ENGINE.start(@replay.state[:round][:challenge], resources: resources)
    count = ENGINE.stimulus(model, seat: 0)[:events].length
    1_600.times { |index| advance(index * 10, background: index > 200 && index < 400) }
    assets = @program.events.map { |event| event[:asset] }
    assert_equal(count, assets.count('duck_quack'), 'Observer missed or replayed part of the duck sequence')
    assert_equal(['duck_quack'], assets.uniq, 'Observer heard a player countdown or input cue')
    assert_equal(nil, request)
    assert_equal(nil, @client.instance_variable_get(:@trace))
    @client.event(nil, before, @replay, viewer, Repository.new)
    replace
    advance(20_000)
    assert_equal(count, @program.events.length, 'Duplicate start/refresh replayed the ducks')
  end

  def cold_ducks(viewer)
    setup_client('count_ducks', viewer: viewer)
    advance(5_000)
    replace
    advance(10_000)
    assert_equal([], @program.events, 'A late observer replayed an old sound sequence')
    assert_equal(nil, request)
  end

  def failed_ducks(viewer)
    begin_ducks(viewer)
    @program.define_singleton_method(:create_sound_from_asset) { |*_args, **_options| nil }
    advance(10)
    assert_equal(nil, request, 'Observer failure cancelled the challenge')
    assert(!@client.instance_variable_get(:@technical_error), 'Observer failure hid valid results')
    assert(@client.local_view, 'Observer lost its safe challenge view')
  end

  def lifecycle(viewer)
    setup_client('count_ducks', viewer: viewer, phase: :preparing)
    before = @replay
    @replay = make_replay('count_ducks')
    @replay.state[:revision] = 1
    @program.now_ms = 30_000
    @client.event(nil, before, @replay, viewer, Repository.new)
    @client.before_wait(@replay, viewer)
    advance(30_001)
    assert_equal([], @program.events, 'An expired start replayed the count stimulus')
    begin_ducks(viewer, id: 2, reset: false)
    advance(30_020)
    assert_equal(1, @program.events.length, 'A new challenge did not begin observation')
    replace do |replay|
      replay.state[:round] = nil
      replay.state[:last_resolution] = {id: 2, cancelled: true}
    end
    assert_equal([], @program.managed, 'Cancellation left observer audio alive')
    advance(50_000)
    assert_equal(1, @program.events.length, 'Cancellation played queued quacks')
    begin_ducks(viewer, id: 3, reset: false)
    advance(50_020)
    assert_equal(2, @program.events.length, 'Previous cancellation suppressed a later challenge')
    @client.update_table_control({'__id' => 91, '__table_owner' => 'Alice', '__players' => %w[Replacement Bob Charlie]})
    assert_equal([], @program.managed, 'Participant change retained old observer audio')
    assert_equal(nil, request)
  end

  def muted_ducks(viewer)
    begin_ducks(viewer)
    @program.enabled = false
    1_600.times { |index| advance(index * 10, background: true) }
    assert(@program.events.any?, 'Muted sequence never advanced')
    assert(@program.events.all? { |entry| entry[:volume].zero? }, 'Muted observation was audible')
    before = @program.events.length
    @program.enabled = true
    advance(20_000)
    assert_equal(before, @program.events.length, 'Returning to the window replayed muted sounds')
    assert_equal([], @program.managed, 'Completed observer playback leaked sound handles')
    assert_equal(nil, request)
  end
end

DuckChallengeObservationTest.new.run
