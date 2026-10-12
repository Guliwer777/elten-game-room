require_relative '../../support/duck_private_round'
require_relative '../../../games/duck_racing_support/private_trace_stream'

include DuckPrivateRoundTest
codec = GameRoomDuckRacing::PrivateTraceStream
protocol = PRIVATE_ROUND
state = private_state
trace = input_trace('żółw 長い音 🎵', count: 350, kind: 'answer')
trace['actions'].each_with_index { |entry, index| entry['input']['value'] += " #{index}-#{index * 731}" }
vault = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
prepared = prepare_private(state, 0, trace, vault: vault)
stream = codec.encode(prepared.envelope)
plain = JSON.generate('nonce' => prepared.envelope.nonce, 'payload' => prepared.envelope.payload)
assert(stream.unpacked_bytes < plain.bytesize, 'Compact trace repeated all original field names')
assert_equal(Zlib::Inflate.inflate(stream.bytes).bytesize, stream.unpacked_bytes)
decoded = codec.decode(stream)
assert_equal(prepared.envelope.payload, decoded['payload'])
assert_equal(prepared.envelope.nonce, decoded['nonce'])
assert(HiddenSubmissions::Commitment.valid?(payload: decoded['payload'], nonce: decoded['nonce'],
  commitment: prepared.envelope.commitment))
assert_equal(1, decoded['payload']['version'], 'Canonical committed schema changed')
assert_equal(trace['actions'].map { |entry| [entry['at'], entry['input']] }, decoded['payload']['trace'])

# Nonce is compressed once with the answer, not sent again with every page.
pages = prepared.reveal_pages
assert(pages.length > 1)
assert(pages.all? { |page| page['version'] == 2 && page['codec'] == codec::CODEC && !page.key?('nonce') })
assert_equal(stream.bytes, pages.map { |page| codec.page_bytes(page) }.join)
shorter = protocol.shrink_reveal_page(pages.first)
assert_equal(codec.page_bytes(pages.first).byteslice(0, codec.page_size(shorter)), codec.page_bytes(shorter))
assert_raises(protocol::CapacityError) do
  protocol.shrink_reveal_page(codec.page(stream, prepared.envelope.payload, 0, 1))
end

def invalid_stream_bytes(bytes, expanded, format = GameRoomDuckRacing::PrivateTraceStream::CODEC)
  GameRoomDuckRacing::PrivateTraceStream::Stream.new(bytes: bytes, unpacked_bytes: expanded, codec: format)
end

# A cached upload from before a reload must retain its exact accepted bytes.
legacy = invalid_stream_bytes(Zlib::Deflate.deflate(plain), plain.bytesize, codec::LEGACY_CODEC)
assert_equal(decoded, codec.decode(legacy))
assert_equal(legacy, codec.from_cache(codec.cache_payload(legacy, prepared.envelope.commitment), prepared.envelope))
assert_equal(stream, codec.from_cache(codec.cache_payload(stream, prepared.envelope.commitment), prepared.envelope))

# Missing fields, false, nil, repeated timestamps and playback-only rows
# must remain distinct, not become default-valued or omitted actions.
edge_payload = prepared.envelope.payload.merge('trace' => [
  [0, {'kind' => 'choose', 'value' => 0, 'press_id' => 0, 'repeat' => false}],
  [0, {'kind' => 'playback_finished', 'playback_id' => 'sample', 'onsets_ms' => [0, 30]}],
  [1, {'kind' => 'answer', 'value' => nil, 'press_id' => 1, 'other' => 0}],
  [1, {'kind' => 'answer', 'value' => '', 'press_id' => 7}]
])
edge_envelope = HiddenSubmissions::Envelope.new(payload: edge_payload, nonce: prepared.envelope.nonce)
assert_equal(edge_payload, codec.decode(codec.encode(edge_envelope))['payload'])
compact = JSON.parse(Zlib::Inflate.inflate(stream.bytes))
[[-1, 1, 'tone'], [0, 0], [0, 128], [0, 1], [0, 1, 'tone', 1],
  [0.1, 1, 'tone'], [0, 4, 'not an integer']].each do |row|
  text = JSON.generate(compact.merge('trace' => [row]))
  assert_raises(codec::InvalidStream) { codec.decode(invalid_stream_bytes(Zlib::Deflate.deflate(text), text.bytesize)) }
end
wire = codec.wire_page(pages.first)
assert_equal(pages.first, codec.normalize_page(wire, session_id: state[:session_id], round_id: state[:round_id], seat: 0))
assert_equal(nil, codec.normalize_page(wire + ['extra'], session_id: state[:session_id], round_id: state[:round_id], seat: 0))
assert_equal(nil, codec.normalize_page(wire, session_id: state[:session_id] + 1, round_id: state[:round_id], seat: 0))

[stream.bytes.byteslice(0, stream.bytes.bytesize - 1), stream.bytes + 'trailing',
  stream.bytes + stream.bytes, 'not zlib', Zlib::Deflate.deflate('{}')].each do |bad|
  assert_raises(codec::InvalidStream) { codec.decode(invalid_stream_bytes(bad, stream.unpacked_bytes)) }
end
assert_raises(codec::InvalidStream) { codec.decode(invalid_stream_bytes(stream.bytes, stream.unpacked_bytes - 1)) }
assert_raises(codec::InvalidStream) { codec.decode(invalid_stream_bytes(stream.bytes, stream.unpacked_bytes + 1)) }
# False small declared output stops streaming inflation before the bomb can
# allocate its full expansion. A true oversized declaration is refused first.
bomb = Zlib::Deflate.deflate('x' * (codec::EXPANSION_ALLOWANCE + 1))
assert_raises(codec::InvalidStream) { codec.decode(invalid_stream_bytes(bomb, 1)) }
assert_raises(codec::CapacityError) { codec.decode(invalid_stream_bytes(bomb, codec::MAX_EXPANDED_BYTES + 1)) }
assert_raises(codec::CapacityError) { codec.decode(invalid_stream_bytes('x' * (codec::MAX_COMPRESSED_BYTES + 1), 1)) }
assert_raises(codec::CapacityError) { codec.decode(invalid_stream_bytes(bomb, codec::EXPANSION_ALLOWANCE + 1)) }
invalid_utf8 = ('{"nonce":"' + '0' * 64 + '","payload":{"word":"').b + "\xff".b + '"}}'.b
duplicate_key = '{"nonce":"' + '0' * 64 + '","nonce":"' + '1' * 64 + '","payload":{}}'
[invalid_utf8, duplicate_key].each do |bad_json|
  assert_raises(codec::InvalidStream) { codec.decode(invalid_stream_bytes(Zlib::Deflate.deflate(bad_json), bad_json.bytesize)) }
end

assert(commit_private(state, prepared, 0))
assert(protocol.forfeit(state, seat: 1, reason: :fixture))
assert(protocol.close_commits(state, now_ms: 2_000))
first = pages.first
bad_pages = [nil, {}, first.merge('version' => 1), first.merge('version' => 3),
  first.merge('codec' => 'zlib-json-2'), first.merge('session' => 92), first.merge('round' => 'old'),
  first.merge('seat' => 1), first.merge('total' => 0), first.merge('total' => codec::MAX_COMPRESSED_BYTES + 1),
  first.merge('total' => 1), first.merge('unpacked_bytes' => codec::MAX_EXPANDED_BYTES + 1),
  first.merge('unpacked_bytes' => 0), first.merge('unpacked_bytes' => 1.0),
  first.merge('offset' => -1), first.merge('offset' => 1.5), first.merge('offset' => first['total']),
  first.merge('data' => ''), first.merge('data' => first['data'] + "\n"), first.merge('data' => '!!!!'),
  first.merge('unknown' => 1), first.merge(:data => first['data'])]
bad_pages.each { |bad| rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: bad, now_ms: 2_001) } }
assert(protocol.accept_reveal_page(state, seat: 0, page: pages.last, now_ms: 2_001))
deadline = state[:reveal_deadlines][0]
rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: pages.last, now_ms: 2_100) }
assert_equal(deadline, state[:reveal_deadlines][0])
overlap = codec.page(stream, prepared.envelope.payload, pages.last['offset'] - 1, 2)
rejected_unchanged(state) { protocol.accept_reveal_page(state, seat: 0, page: overlap, now_ms: 2_101) }
rejected_unchanged(state) do
  protocol.accept_reveal_page(state, seat: 0, page: first.merge('unpacked_bytes' => first['unpacked_bytes'] + 1), now_ms: 2_102)
end
pages[0...-1].each { |page| assert(protocol.accept_reveal_page(state, seat: 0, page: page, now_ms: 2_103)) }
assert_equal(:finished, state[:phase])
assert_equal(prepared.envelope.payload, state[:reveals][0])

# A different valid zlib stream is not sufficient: canonical scope, shape,
# nonce and the original salted commitment still decide final acceptance.
mutations = [
  {'nonce' => 'f' * 64, 'payload' => prepared.envelope.payload},
  {'nonce' => prepared.envelope.nonce, 'payload' => prepared.envelope.payload.merge('seat' => 1)},
  {'nonce' => prepared.envelope.nonce, 'payload' => prepared.envelope.payload.merge('score' => 99)},
  {'nonce' => prepared.envelope.nonce, 'payload' => prepared.envelope.payload.merge('trace' => [[0, {'kind' => 'tone', 'press_id' => 1}], [1, {'kind' => 'tone', 'press_id' => 1}]])}
]
mutations.each do |changed|
  target = private_state
  assert(commit_private(target, prepared, 0))
  assert(protocol.forfeit(target, seat: 1, reason: :fixture))
  assert(protocol.close_commits(target, now_ms: 2_000))
  json = JSON.generate(changed)
  bad_stream = invalid_stream_bytes(Zlib::Deflate.deflate(json), json.bytesize, codec::LEGACY_CODEC)
  page = codec.page(bad_stream, prepared.envelope.payload, 0, bad_stream.bytes.bytesize)
  rejected_unchanged(target) { protocol.accept_reveal_page(target, seat: 0, page: page, now_ms: 2_001) }
end

puts 'PASS Duck compressed stream: unchanged canonical commitment/Unicode, bounded inflation, exact ranges, malformed/trailing/versioned data, duplicates and final validation'
