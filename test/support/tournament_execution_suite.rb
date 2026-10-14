# encoding: UTF-8
require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../run'

# Maintained entry points run in separate processes. Historical versions stay
# available by explicit path, but are never counted again as independent coverage.
module TournamentExecutionSuite
  ROOT = File.expand_path('../..', __dir__)
  GROUPS = {
    'entry' => %w[ft2b1_hub ft2b1_entry_native ft2b1_target_provider
      ft2b1_clock_ordinary ft2b1_k03_diagnostics ft2b1_k03_hub_transition
      ft2b1_fix1_current ft2b1_fix1_provenance ft2b1_fix1_native_evidence
      ft2b1_fix1_catalog_native ft2b1_connection_unwind],
    'ui' => %w[ft2b1_target_ui ft2b1_selection_status ft2b1_deadline_focus
      ft2b1_ui_cas ft2b1_ui_catalog ft2b1_ui_confirmed_refresh
      ft2b1_ui_deadline_v2 ft2b1_ui_focus ft2b1_ui_history
      ft2b1_ui_missing_receipt ft2b1_ui_owner ft2b1_ui_readonly],
    'lifecycle' => %w[ft2b1_ui_connection_construction ft2b1_ui_construction
      ft2b1_ui_lifecycle ft2b1_ui_nested_diagnostic ft2b1_ui_nested_presentation_v3
      ft2b1_ui_primary_v2 ft2b1_deadline_boundary],
    'native' => %w[ft2b1_native_aggregate ft2b1_native_ambient ft2b1_native_capability
      ft2b1_native_cleanup ft2b1_native_closed_view ft2b1_native_envelope
      ft2b1_native_exact ft2b1_native_lifecycle ft2b1_native_limits
      ft2b1_native_open_cleanup ft2b1_native_partial_runtime ft2b1_native_partial
      ft2b1_native_precommit ft2b1_native_preflight ft2b1_native_primary
      ft2b1_native_retention]
  }.transform_values { |names| names.map { |name| {script: "test/tournaments/#{name}_test.rb"}.freeze }.freeze }.freeze

  def self.jobs(group)
    return GROUPS.fetch(group).map(&:dup) if GROUPS.key?(group)
    if group == 'encoding'
      return %w[source binary].product(%w[pl en missing-new-pl]).map do |mode, language|
        {script: 'test/localization/ft2b1_native_encoding_v2_test.rb', args: [mode, language]}
      end
    end
    raise ArgumentError, "Unknown tournament group: #{group}" unless %w[cold recovery compatibility].include?(group)
    rows = []
    if group == 'cold'
      %w[healthy lost_target lost_ready].zip(%w[c4 c5 c6]).each do |variant, name|
        %w[A B].each do |phase|
          rows << {script: 'test/tournaments/ft2b1_target_cold_v3_test.rb', args: [phase, variant, name]}
        end
      end
    elsif group == 'recovery'
      %w[A B].each { |phase| rows << {script: 'test/tournaments/ft2b1_native_cold_test.rb', args: [phase, 'suite']} }
      %w[a b].each { |phase| rows << {script: "test/tournaments/ft2_runtime_cold_#{phase}_test.rb", evidence_name: "runtime-#{phase}"} }
    else
      %w[a b].each { |phase| rows << {script: "test/tournaments/ft2_compatibility_boundary_#{phase}_test.rb"} }
    end
    rows
  end

  def self.read_catalog(path)
    bytes = File.binread(path)
    raise 'Expected GNU MO little endian' unless bytes.unpack1('V') == 0x950412de
    _, _, count, keys, values = bytes.unpack('V5')
    count.times.to_h do |index|
      kl, ko = bytes.byteslice(keys + index * 8, 8).unpack('V2')
      vl, vo = bytes.byteslice(values + index * 8, 8).unpack('V2')
      [bytes.byteslice(ko, kl), bytes.byteslice(vo, vl)]
    end
  end

  def self.write_catalog(path, records)
    count, key_data, value_data = records.size, ''.b, ''.b
    start = 28 + count * 16
    keys = records.keys.map do |key|
      row = [key.bytesize, start + key_data.bytesize].pack('V2')
      key_data << key << "\0"
      row
    end.join
    values = records.values.map do |value|
      row = [value.bytesize, start + key_data.bytesize + value_data.bytesize].pack('V2')
      value_data << value << "\0"
      row
    end.join
    File.binwrite(path, [0x950412de, 0, count, 28, 28 + count * 8, 0, 0].pack('V7') + keys + values + key_data + value_data)
  end

  def self.prepare_encoding(scratch, root: ROOT)
    removed = JSON.parse(File.read(File.join(root, 'test/fixtures/tournaments/ft2b1_missing_translations.json'), encoding: 'UTF-8'))
    records = read_catalog(File.join(root, 'locale/PL.mo'))
    raise 'Missing fixture keys' unless removed.size == 33 && removed.all? { |key| records.key?(key.b) }
    records = records.reject { |key, _| removed.include?(key.dup.force_encoding('UTF-8')) }.sort.to_h
    directory = File.join(scratch, 'shared/missing')
    FileUtils.mkdir_p(directory)
    write_catalog(File.join(directory, 'PL.mo'), records)
    File.write(File.join(directory, 'removed.json'), JSON.pretty_generate(removed))
  end

  def self.entries(group, scratch:, root: ROOT, only: nil)
    prepare_encoding(scratch, root: root) if group == 'encoding'
    snapshot = Dir.glob('{lib,games,content}/**/*.rb', base: root).sort.to_h do |path|
      [path, Digest::SHA256.file(File.join(root, path)).hexdigest]
    end
    rows = jobs(group)
    rows = rows.select { |job| File.basename(job[:script]).include?(only) } if only
    raise 'No tournament scenarios selected' if rows.empty?
    rows.each_with_index.map do |job, index|
      name = job[:evidence_name] || "j#{index}"
      evidence = File.join(scratch, 'runs', name)
      FileUtils.mkdir_p(evidence)
      File.write(File.join(evidence, 'source-before.json'), JSON.pretty_generate(snapshot))
      job.reject { |key, _| key == :evidence_name }.merge(ruby_args: ['-EUTF-8'], env: {
        'FT2_SOURCE' => root, 'FT2_SCRATCH' => scratch, 'TMPDIR' => scratch, 'ENTRY_EVIDENCE' => evidence
      })
    end
  end

  def self.run(group, only: nil)
    temporary = File.join(ROOT, 'tmp')
    FileUtils.mkdir_p(temporary)
    # Short paths keep local-test backend identities within the public contract.
    scratch = Dir.mktmpdir('t', temporary)
    results = GameRoomTestRunner.run(entries(group, scratch: scratch, only: only), root: ROOT,
      report: File.join(scratch, 'results.json'))
    raise "Tournament #{group} failed; evidence: #{scratch}" unless GameRoomTestRunner.success?(results)
    puts "PASS tournament #{group}: #{results.size} isolated processes; evidence: #{scratch}"
  end
end
