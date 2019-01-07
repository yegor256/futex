# frozen_string_literal: true

# (The MIT License)
#
# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'minitest/autorun'
require 'tmpdir'
require 'threads'
require 'digest'
require 'securerandom'
require_relative '../lib/futex'

# Futex test.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
class FutexTest < Minitest::Test
  def test_syncs_access_to_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a/b/c/file.txt')
      Threads.new(2).assert do |_, r|
        Futex.new(path, logging: true).open do |f|
          text = "op no.#{r}"
          IO.write(f, text)
          assert_equal(text, IO.read(f))
        end
      end
    end
  end

  def test_syncs_read_only_access_to_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'file.txt')
      text = 'Hello, world!'
      IO.write(path, text)
      Threads.new(2).assert do
        Futex.new(path).open(false) do |f|
          assert_equal(text, IO.read(f))
        end
      end
    end
  end

  def test_syncs_access_to_file_in_slow_motion
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a/b/c/file.txt')
      Threads.new(20).assert(200) do |_, r|
        Futex.new(path).open do |f|
          text = "op no.#{r}"
          IO.write(f, text)
          sleep 0.01
          assert_equal(text, IO.read(f))
        end
      end
    end
  end

  def test_raises_if_cant_lock
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'the/simple/file.txt')
      Thread.start do
        Futex.new(path).open do
          sleep 10
        end
      end
      sleep 0.1
      ex = assert_raises(Futex::CantLock) do
        Futex.new(path, timeout: 0.1).open do |f|
          # Will never reach this point
        end
      end
      assert(ex.message.include?('can\'t get exclusive access to the file'), ex)
      assert(!ex.start.nil?)
    end
  end

  def test_exclusive_and_shared_locking
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'g/e/f/file.txt')
      Threads.new(20).assert(1000) do |_, r|
        if (r % 50).zero?
          Futex.new(path).open do |f|
            text = SecureRandom.hex(1024)
            hash = hash(text)
            IO.write(f, text + ' ' + hash)
          end
        end
        Futex.new(path).open(false) do |f|
          if File.exist?(f)
            text, hash = IO.read(f, text).split(' ')
            assert_equal(hash, hash(text))
          end
        end
      end
    end
  end

  def test_exclusive_and_shared_locking_in_processes
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'g/e/f/file.txt')
      10.times do
        Process.fork do
          Threads.new(20).assert(1000) do |_, r|
            if (r % 50).zero?
              Futex.new(path).open do |f|
                text = SecureRandom.hex(1024)
                hash = hash(text)
                IO.write(f, text + ' ' + hash)
              end
            end
            Futex.new(path).open(false) do |f|
              if File.exist?(f)
                text, hash = IO.read(f, text).split(' ')
                assert_equal(hash, hash(text))
              end
            end
          end
          exit!(0)
        end
      end
      Process.waitall.each do |p, e|
        raise "Failed in PID ##{p}: #{e}" unless e.exitstatus.zero?
      end
    end
  end

  def test_cleans_up_the_mess
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        IO.write(f, 'hey')
        FileUtils.rm(f)
      end
      assert_equal(2, Dir.new(dir).count)
    end
  end

  def test_sets_thread_vars
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        assert_equal(
          "#{f}.lock",
          Thread.current.thread_variable_get(:futex_lock)
        )
        assert(
          Thread.current.thread_variable_get(:futex_badge).include?('-ex/nil')
        )
      end
    end
  end

  def test_removes_thread_vars
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        # nothing
      end
      assert(Thread.current.thread_variable_get(:futex_lock).nil?)
    end
  end

  def test_saves_calling_file_name_in_lock
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        badge = IO.read("#{f}.lock")
        assert(badge.include?('test/test_futex.rb:'), badge)
      end
    end
  end

  def test_works_without_block_given
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open
    end
  end

  def test_works_with_broken_counts_file
    IO.write(Futex::COUNTS, 'fds')
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        assert(!File.exist?(f))
      end
    end
  end

  private

  def hash(text)
    Digest::SHA256.hexdigest(text)
  end
end
