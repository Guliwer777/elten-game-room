require_relative '../support/background_help_game_screen'

# Only the outer host loop and peripherals are doubled. No form update/frame
# is called while covered; production Progress and SessionRunner must do it.
module EltenAPI::UI
  def loop_update; :host; end
end
class RealtimeOtherScene
  include EltenAPI::UI
end
$mainthread = $currentthread = Thread.current
scene = RealtimeOtherScene.new

# Form, help and context menu share one clock gate, not two engines.
now, calls = 0.0, []
program, form, menu = Program.new, Form.new([]), Object.new
progress = GameRoomRealtime::Progress.new(program: program, clock: -> { now }, key: 'probe') do |covered|
  calls << [now, covered, Thread.current]
end
progress.attach(form)
$lastactivecontrols = [form]
scene.send(:loop_update)
assert(calls.empty?, 'Bridge also advanced a visible form')
progress.timer.update
progress.update(background: true)
assert(calls.size == 1, 'Same frame advanced twice')
$lastactivecontrols = [menu]
now += 0.016
scene.send(:loop_update)
progress.timer.update
assert(calls.size == 2 && calls.last[1], 'Same-thread menu stopped/doubled the timer')
Thread.new do
  $currentthread = Thread.current
  now += 0.016
  scene.send(:loop_update)
  assert(calls.last[1] && calls.last[2] == Thread.current, 'Another scene ran outside its active UI')
ensure
  $currentthread = $mainthread
end.value
progress.detach
now += 0.016
scene.send(:loop_update)
assert(calls.size == 4, 'Temporary view detach stopped progression')
progress.close
now += 0.016
scene.send(:loop_update)
assert(calls.size == 4, 'Closed timer survived its client')
puts 'PASS realtime progress: visible/menu/other-thread/detached share one active-UI timer and close releases it'

# Existing native session repository and production background screen start a
# bot match with no game form, save its point, then handle a new game and close.
game = GameRoomGames::AudioBall.new
clients, audios, network = [], [], {}
game.define_singleton_method(:build_client) do |_program, **_services|
  audio = AudioBallTestAudio.new
  client = GameRoomAudioBall::Client.new(Program.new, self, clock: -> { $help_clock }, audio: audio,
    channel_factory: ->(**args) { AudioBallTestChannel.new(network, **args) })
  clients << client
  audios << audio
  client
end
h, screen = screen_fixture(game, bots: 1)
bot_serves_audio_ball(h)
$lastactivecontrols = [menu]
h.as('Alice') { screen.start_covered_session(covered: -> { true }, activity_cursor: 0) }
runner = screen.instance_variable_get(:@session_runner)
def await_background(scene, runner)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 6
  until yield
    raise 'Background match did not progress' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    $help_clock += 0.016
    scene.send(:loop_update)
    error = runner.take_error
    raise error if error
    sleep 0.001
  end
end
begin
  await_background(scene, runner) { h.replay('Alice').state[:rally] >= 1 }
  await_background(scene, runner) { audios.first.calls.any? { |row| row.first == :point } }
  assert(h.events('Alice').count { |e| e['action'] == 'audio_ball_point' } == 1, 'Covered point duplicated')
  first = clients.first
  assert(!first.instance_variable_get(:@closed), 'Covered match closed at first point')
  assert(screen.instance_variable_get(:@layout).nil?, 'Covered game created a form')
  h.start
  bot_serves_audio_ball(h)
  await_background(scene, runner) { clients.size == 2 }
  assert(first.instance_variable_get(:@closed), 'Rematch retained old client')
  await_background(scene, runner) { h.replay('Alice').state[:rally] >= 1 }
  assert(audios.size == 2 && network['alice'].reasons.empty?, 'Rematch caused an avoidable transport reset')
  runner.close
  scene.send(:loop_update)
  assert(clients.last.instance_variable_get(:@closed), 'Closed table retained a background physics/audio client')
  puts 'PASS realtime background screen: bot starts, durable point/audio, rematch and closed-table cleanup without a form'
ensure
  screen.close_covered_session
  clients.each(&:close)
  $lastactivecontrols = nil
end
