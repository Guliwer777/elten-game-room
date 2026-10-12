require_relative '../../support/duck_private_round'
require_relative '../../../games/duck_racing_support/wire_budget'

include DuckPrivateRoundTest

class DuckNextPageFixture
  include DuckPrivateRoundTest
  attr_accessor :limit, :revision
  attr_reader :state, :storage, :vault, :prepared, :replay, :calls, :trace

  def initialize(count: 350, value: nil, limit: 1536)
    @state = private_state(commit_deadline_ms: nil)
    @storage = HiddenSubmissions::MemoryStorage.new
    @vault = HiddenSubmissions::Vault.new(storage)
    @trace = input_trace(value || 'answer', count: count, kind: 'answer')
    trace['actions'].each_with_index { |entry, index| entry['input']['value'] = "#{index}-#{index * 179}" } unless value
    @limit, @revision, @calls, @now_ms = limit, 12, [], 2_001
    @replay = GameRoomGames::Replay.new(accepted_events: [], state: {session_id: state[:session_id],
      bot_controller_epoch: 'epoch-a'})
    @prepared = prepare_private(state, 0, trace, vault: vault, page_builder: method(:build))
  end

  def begin_reveal
    assert(commit_private(state, prepared, 0))
    assert(PRIVATE_ROUND.forfeit(state, seat: 1, reason: :fixture))
    assert(PRIVATE_ROUND.close_commits(state, now_ms: 2_000))
  end

  def build(page)
    calls << page.fetch('offset')
    GameRoomDuckRacing::WireBudget.plan('duck_racing', data(page), replay: replay, actor: 'account-0', limit: limit)
  end

  def data(page)
    {'action' => 'reveal', 'challenge' => 2, 'page' => page, 'revision' => revision,
      'session' => state[:session_id], 'at' => 1_791_676_590_000 + revision}
  end

  def next_page
    PRIVATE_ROUND.recover_next_reveal_page(state, seat: 0, user: 'account-0', vault: vault,
      page_builder: method(:build))
  end

  def accept(page)
    assert(PRIVATE_ROUND.accept_reveal_page(state, seat: 0, page: page, now_ms: @now_ms += 1))
    @revision += 1
    replay.accepted_events << {'sequence' => revision}
  end

  # Full preflight/recovery and the executor's single-page fast path must
  # agree on gaps and exact EventCommand bytes in the new byte-stream format.
  def full_prepared
    PRIVATE_ROUND.recover(state, seat: 0, user: 'account-0', vault: vault, page_builder: method(:build))
  end

  def compare_next
    before = Marshal.dump([state, storage.read, replay])
    old = full_prepared
    expected = PRIVATE_ROUND.next_reveal_page(state, old)
    calls.clear
    actual = next_page
    assert_equal(expected, actual, 'Optimization changed the next missing page')
    assert_equal([actual.fetch('offset')], calls.uniq, 'Compressed a page other than the next missing page')
    assert_equal(JSON.generate(expected), JSON.generate(actual))
    assert_equal(build(expected).events, build(actual).events, 'Wire EventCommand bytes changed')
    assert_equal(before, Marshal.dump([state, storage.read, replay]), 'Planning changed private or replicated state')
    actual
  end
end

checks = []
fixture = DuckNextPageFixture.new
assert(fixture.calls.uniq.length > 1, 'Initial commit preflight stopped checking the full trace')
fixture.begin_reveal
pages = 0
until fixture.state[:phase] == :finished
  fixture.accept(fixture.compare_next)
  pages += 1
end
assert(pages > 10)
assert_equal(fixture.trace['actions'].map { |entry| [entry['at'], entry['input']] }, fixture.state[:reveals][0]['trace'])
checks << 'single missing page agrees with full byte-stream planner; complete preflight retained'

# Gaps must end at an already accepted out-of-order page. A changed transport
# grant or metadata must repartition only missing input, never re-encode an
# accepted page or reuse a stale final packet.
fixture = DuckNextPageFixture.new(limit: 4096)
fixture.begin_reveal
original = fixture.prepared.reveal_pages
assert(original.length > 2)
fixture.accept(original.last)
fixture.accept(original[1])
known = Marshal.load(Marshal.dump(fixture.state[:pages][0]))
fixture.limit = 1536
fixture.revision = 999_999_999
fixture.replay.state[:bot_controller_epoch] = 'e' * 64
fixture.replay.accepted_events << {'sequence' => 9_999_998}
pages = 0
until fixture.state[:phase] == :finished
  page = fixture.compare_next
  known.each_value do |accepted|
    first, last = accepted['offset'], accepted['offset'] + PRIVATE_ROUND.reveal_page_size(accepted)
    assert(page['offset'] >= last || page['offset'] + PRIVATE_ROUND.reveal_page_size(page) <= first, 'Next page overlaps an accepted boundary')
  end
  fixture.accept(page)
  pages += 1
  fixture.limit = 4096 if pages == 3
end
assert_equal(fixture.trace['actions'].map { |entry| [entry['at'], entry['input']] }, fixture.state[:reveals][0]['trace'])
checks << 'out-of-order accepted pages and gaps survive shrinking/growing limit, revision and epoch changes'

fixture = DuckNextPageFixture.new(count: 0)
fixture.begin_reveal
page = fixture.compare_next
assert(PRIVATE_ROUND.reveal_page_size(page).positive?)
fixture.accept(page)
assert_equal([], fixture.state[:reveals][0]['trace'])
assert_equal(nil, fixture.next_page)
checks << 'empty trace sends one valid page, then resolved attempts stop'

fixture = DuckNextPageFixture.new(count: 10)
before = Marshal.dump(fixture.state)
assert_equal(nil, fixture.next_page)
assert_equal(before, Marshal.dump(fixture.state))
fixture.begin_reveal
page = fixture.next_page
page['data'].replace('changed by caller')
assert(fixture.next_page['data'] != 'changed by caller')
assert(PRIVATE_ROUND.forfeit(fixture.state, seat: 0, reason: :gone))
assert_equal(nil, fixture.next_page)
checks << 'no early reveal, returned data is detached, forfeited attempt stops'

fixture = DuckNextPageFixture.new(count: 10)
fixture.begin_reveal
original = fixture.storage.read
before = Marshal.dump(fixture.state)
bad_payloads = [nil, {}, {'score' => 999}, original['entries'].values.first['payload'].merge('seat' => 1)]
bad_payloads.each do |bad|
  fixture.storage.update do |root|
    root.replace(Marshal.load(Marshal.dump(original)))
    root['entries'].values.first['payload'] = bad
  end
  assert_equal(nil, fixture.next_page)
  assert_equal(before, Marshal.dump(fixture.state))
end
fixture.storage.update { |root| root.replace('entries' => {}) }
assert_equal(nil, fixture.next_page)
fixture.storage.update { |root| root.replace(Marshal.load(Marshal.dump(original))) }
fixture.state[:commitments][0] = 'f' * 64
assert_equal(nil, fixture.next_page)
checks << 'missing/corrupt vault and wrong commitment produce no page, score, forfeit or state mutation'

# A payload that happens to hash correctly still needs the canonical envelope
# shape enforced by the previous full planner (including nonce format).
fixture = DuckNextPageFixture.new(count: 10)
fixture.begin_reveal
fixture.storage.update do |root|
  entry = root['entries'].values.first
  entry['nonce'] = 'not-a-canonical-nonce'
  entry['commitment'], = HiddenSubmissions::Commitment.create(entry['payload'], nonce: entry['nonce'])
  fixture.state[:commitments][0] = entry['commitment']
end
assert_equal(nil, fixture.next_page)
assert_equal({}, fixture.state[:reveals])
checks << 'invalid nonce is rejected even when its recomputed digest matches'

fixture = DuckNextPageFixture.new(count: 1)
fixture.begin_reveal
[{seat: 9, user: 'account-0'}, {seat: 0, user: 'other-account'}, {seat: 1, user: 'account-0'}].each do |identity|
  assert_equal(nil, PRIVATE_ROUND.recover_next_reveal_page(fixture.state, **identity, vault: fixture.vault,
    page_builder: fixture.method(:build)))
end
fixture.state[:session_id] += 1
assert_equal(nil, fixture.next_page)
fixture.state[:session_id] -= 1
fixture.state[:round_id] = 'another-round'
assert_equal(nil, fixture.next_page)
checks << 'account, seat, session and round isolation remain intact'

random = Random.new(73)
text = Array.new(900) { (33 + random.rand(90)).chr }.join
fixture = DuckNextPageFixture.new(count: 1, value: text, limit: 16_384)
fixture.begin_reveal
fixture.limit = 1536
until fixture.state[:phase] == :finished
  fixture.accept(fixture.next_page)
end
assert_equal(text, fixture.state[:reveals][0]['trace'][0][1]['value'])
checks << 'one large input can now span native packets without truncating or changing its value'

fixture = DuckNextPageFixture.new
fixture.begin_reveal
fixture.limit = 1
before = Marshal.dump(fixture.state)
assert_raises(PRIVATE_ROUND::CapacityError) { fixture.next_page }
assert_equal(before, Marshal.dump(fixture.state))
assert_equal({}, fixture.state[:reveals])
assert_equal({1 => :fixture}, fixture.state[:forfeits])
checks << 'unusable native budget fails without accepting truncated input or inventing a gameplay loss'

puts JSON.pretty_generate(status: 'PASS', checks: checks)
