# frozen_string_literal: true
require 'fileutils'
require 'tmpdir'

module GameRoomTest
  # Keep test evidence in the ignored workspace directory, without depending
  # on another scenario (or an earlier local run) to create its parent.
  module TemporaryDirectory
    ROOT = File.expand_path('../..', __dir__)

    def self.parent(root: ROOT)
      parent = File.join(root, 'tmp')
      FileUtils.mkdir_p(parent)
      parent
    end

    def self.create(prefix, root: ROOT, &block)
      Dir.mktmpdir(prefix, parent(root: root), &block)
    end
  end
end
