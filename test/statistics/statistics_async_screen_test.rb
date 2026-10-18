require_relative '../support/quiz_creator_native'
require_relative '../support/native_tasks'
require EltenTestHost.file('src/ui/controls/table_box.rb')
Object.const_set(:TableBox, EltenAPI::Controls.const_get(:TableBox)) unless Object.const_defined?(:TableBox)
require_relative '../../lib/game_statistics_screen'

GameRoomLocalization.boot(host_language: 'en', settings: {'interface_language' => 'en'})
registry = Struct.new(:ids) do
  def name(id); id.capitalize; end
end.new(['quiz'])
data = {'visitors' => 12, 'players' => 8, 'started' => 6, 'completed' => 4,
  'first_day' => 20261001, 'partial' => false, 'games' => []}
ui = Thread.current
reads = []
gate = Queue.new
entered = Queue.new
runtime = TestTaskRuntime.new('statistics-responsive')
screen = nil
def statistics_frame(form, keys: [])
  state = "\0" * 256
  keys.each { |key| state.setbyte(key, 0x80) }
  EltenAPI::KeyboardState.update(raw_state: state, events: keys.map { |key| [key, true] }, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
  $input_frame_serial = $input_frame_serial.to_i + 1
  $keyboard_state_frame_serial = $input_frame_serial
  $keyboard_state_frame_thread = Thread.current
  $activecontrols = []
  form.update
end
reader = lambda do |period, *_tokens|
  reads << [period.key, Thread.current]
  # The old path calls the reader before constructing its form. Do not hang
  # that negative control: its UI-thread read is the regression assertion.
  if Thread.current != ui
    entered << period.key
    gate.pop if period.key == 'today'
  end
  data.merge('visitors' => period.key == 'today' ? 12 : 99)
end

Form.driver = lambda do |form|
  assert(reads.none? { |_, thread| thread == ui }, 'Statistics read before the responsive form, on its UI thread')
  assert(form.fields.first.text == 'Loading statistics', 'Initial view did not expose loading without blocking')
  assert(form.cancel_button && form.fields[1].options.include?('All time'), 'Loading view cannot be navigated or closed')
  assert(form.instance_variable_get(:@timers).to_a.empty?, 'Statistics added network polling')
  Timeout.timeout(5) { entered.pop }
  summary, periods, table, refresh = form.fields.first(4)
  form.index = 1
  [1, 2, 3].each do |index|
    periods.index = index
    periods.trigger(:move)
  end
  assert(form.index == 1 && reads.map(&:first) == ['today'], 'Period changes blocked or started concurrent reads')
  assert(table.rows.empty? && summary.text == 'Loading statistics', 'Old counts survived a pending period change')
  gate << true
  Timeout.timeout(5) do
    loop do
      statistics_frame(form)
      break if summary.text.include?('Visitors: 99')
      Thread.pass
    end
  end
  assert(reads.map(&:first) == %w[today last_365], 'Rapid navigation did not coalesce to the latest period')
  assert(summary.text.include?('Last 365') && form.index == 1, 'Stale report replaced the selected period or focus')
  assert(periods.options.include?('2025'), 'Initial year discovery was lost when the period changed')
  before = reads.length
  10.times { statistics_frame(form) }
  assert(reads.length == before, 'An idle view performed extra reads')
  form.cancel_button.trigger(:press)
end
begin
  Programs.with_runtime(runtime) do
    screen = GameRoomStatisticsScreen.new(program: Object.new, reader: reader,
      years_reader: ->(*) { [2025] }, registry: registry, today: Date.new(2026, 10, 18))
    screen.run
  end
ensure
  gate << true
  runtime.close
end

# Closing must not join or kill a pending HTTP read. Test native Escape as
# well as Back, account invalidation and runtime teardown, before releasing it.
[:back, :escape, :account, :runtime].each do |closing|
  runtime = TestTaskRuntime.new("statistics-close-#{closing}")
  gate, entered = Queue.new, Queue.new
  valid, completed, token_seen = true, false, nil
  Form.driver = lambda do |form|
    form.instance_variable_set(:@wait, true)
    Timeout.timeout(5) { entered.pop }
    20.times { form.fields[3].trigger(:press) }
    assert(reads.map(&:first) == ['years'], 'Repeated Refresh queued duplicate reads while the same period was loading')
    summary = form.fields.first
    case closing
    when :back then form.cancel_button.trigger(:press)
    when :escape then statistics_frame(form, keys: [27])
    when :account then valid = false; statistics_frame(form)
    when :runtime then runtime.close; statistics_frame(form)
    end
    assert(!form.instance_variable_get(:@wait) && !completed, "#{closing} waited for the blocked worker")
    assert(token_seen.cancelled?, "#{closing} did not cancel its read token")
    assert(form.instance_variable_get(:@statistics_update).nil?, "#{closing} left an active UI callback")
    gate << true
    wait_background_work(screen.instance_variable_get(:@work))
    assert(summary.text == 'Loading statistics' && reads.map(&:first) == ['years'], "#{closing} applied a late result or continued fetching")
  end
  reads = []
  begin
    Programs.with_runtime(runtime) do
      screen = GameRoomStatisticsScreen.new(program: Object.new, registry: registry,
        today: Date.new(2026, 10, 18), valid: -> { valid },
        years_reader: ->(token) do
          token_seen = token
          reads << ['years', Thread.current]
          entered << true
          gate.pop
          completed = true
          [2025]
        end,
        reader: ->(period, _token) { reads << [period.key, Thread.current]; data })
      screen.run
    end
  ensure
    gate << true
    runtime.close
  end
end
puts 'PASS responsive statistics: native UI, coalescing, stale results, no polling, Escape/Back/account/runtime during blocked I/O'
