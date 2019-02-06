# frozen_string_literal: true

# (The MIT License)
#
# Copyright (c) 2018-2019 Yegor Bugayenko
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

require 'fileutils'
require 'time'
require 'singleton'
require 'json'

# Futex (file mutex) is a fine-grained mutex that uses a file, not an entire
# thread, like <tt>Mutex</tt> does. Use it like this:
#
#  require 'futex'
#  Futex.new('/tmp/my-file.txt').open |f|
#    IO.write(f, 'Hello, world!')
#  end
#
# The file <tt>/tmp/my-file.txt.lock<tt> will be created and
# used as an entrance lock. If the file is already locked by another thread
# or another process, exception <tt>Futex::CantLock</tt> will be raised.
#
# If you are not planning to write to the file, to speed things up, you may
# want to get a non-exclusive access to it, by providing <tt>false</tt> to
# the method <tt>open()</tt>:
#
#  require 'futex'
#  Futex.new('/tmp/my-file.txt').open(false) |f|
#    IO.read(f)
#  end
#
# For more information read
# {README}[https://github.com/yegor256/futex/blob/master/README.md] file.
#
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018-2019 Yegor Bugayenko
# License:: MIT
class Futex
  # Exception that is raised when we can't lock because of some other
  # process that is holding the lock now. There is an encapsulated
  # <tt>start</tt> attribute of type <tt>Time</tt>, which points to the time
  # when we started to try to acquire lock.
  class CantLock < StandardError
    attr_reader :start
    def initialize(msg, start)
      @start = start
      super(msg)
    end
  end

  # Global file for locks counting
  COUNTS = File.join(Dir.tmpdir, 'futex.lock').freeze

  # Creates a new instance of the class.
  def initialize(path, log: STDOUT, timeout: 16, sleep: 0.005,
    lock: path + '.lock', logging: false)
    @path = path
    @log = log
    @logging = logging
    @timeout = timeout
    @sleep = sleep
    @lock = lock
  end

  # Open the file. By default the file will be locked for exclusive access,
  # which means that absolutely no other process will be able to do the same.
  # This type of access (exclusive) is supposed to be used when you are
  # making changes to the file. However, very often you may need just to
  # read it and it's OK to let many processes do the reading at the same time,
  # provided none of them do the writing. In that case you should call this
  # method <tt>open()</tt> with <tt>false</tt> first argument, which will mean
  # "shared" access. Many threads and processes may have shared access to the
  # same lock file, but they all will stop and wait if one of them will require
  # an "exclusive" access. This mechanism is inherited from POSIX, read about
  # it <a href="http://man7.org/linux/man-pages/man2/flock.2.html">here</a>.
  def open(exclusive = true)
    FileUtils.mkdir_p(File.dirname(@lock))
    step = (1 / @sleep).to_i
    start = Time.now
    prefix = exclusive ? '' : 'non-'
    b = badge(exclusive)
    Thread.current.thread_variable_set(:futex_lock, @lock)
    Thread.current.thread_variable_set(:futex_badge, b)
    open_synchronized(@lock) do |f|
      cycle = 0
      loop do
        if f.flock((exclusive ? File::LOCK_EX : File::LOCK_SH) | File::LOCK_NB)
          Thread.current.thread_variable_set(:futex_cycle, nil)
          Thread.current.thread_variable_set(:futex_time, nil)
          break
        end
        sleep(@sleep)
        cycle += 1
        Thread.current.thread_variable_set(:futex_cycle, cycle)
        Thread.current.thread_variable_set(:futex_time, Time.now - start)
        if Time.now - start > @timeout
          raise CantLock.new("#{b} can't get #{prefix}exclusive access \
to the file #{@path} because of the lock at #{@lock}, after #{age(start)} \
of waiting: #{IO.read(@lock)} (modified #{age(File.mtime(@lock))} ago)",
          File.mtime(@lock))
        end
        next unless (cycle % step).zero? && Time.now - start > @timeout / 2
        debug("#{b} still waiting for #{prefix}exclusive \
access to #{@path}, #{age(start)} already: #{IO.read(@lock)} \
(modified #{age(File.mtime(@lock))} ago)")
      end
      debug("Locked by #{b} in #{age(start)}, #{prefix}exclusive: \
#{@path} (attempt no.#{cycle})")
      IO.write(@lock, b)
      acq = Time.now
      res = block_given? ? yield(@path) : nil
      debug("Unlocked by #{b} in #{age(acq)}, #{prefix}exclusive: #{@path}")
      res
    end
  ensure
    Thread.current.thread_variable_set(:futex_cycle, nil)
    Thread.current.thread_variable_set(:futex_time, nil)
    Thread.current.thread_variable_set(:futex_lock, nil)
    Thread.current.thread_variable_set(:futex_badge, nil)
  end

  private

  def badge(exclusive)
    tname = Thread.current.name
    tname = 'nil' if tname.nil?
    "##{Process.pid}-#{exclusive ? 'ex' : 'sh'}/#{tname}[#{caller(2..2).first}]"
  end

  def age(time)
    sec = Time.now - time
    return "#{(sec * 1_000_000).round}μs" if sec < 0.001
    return "#{(sec * 1000).round}ms" if sec < 1
    return "#{sec.round(2)}s" if sec < 60
    return "#{(sec / 60).round}m" if sec < 60 * 60
    "#{(sec / 3600).round}h"
  end

  def debug(msg)
    return unless @logging
    if @log.respond_to?(:debug)
      @log.debug(msg)
    elsif @log.respond_to?(:puts)
      @log.puts(msg)
    end
  end

  def open_synchronized(path)
    path = File.absolute_path(path)
    file = nil
    synchronized do |counts|
      file = File.open(path, File::CREAT | File::RDWR)
      refs = deserialize(IO.read(counts.path))
      refs[path] = (refs[path] || 0) + 1
      IO.write(counts.path, serialize(refs))
    end
    yield file
  ensure
    synchronized do |counts|
      file&.close
      refs = deserialize(IO.read(counts.path))
      refs[path] = (refs[path] || 1) - 1
      if refs[path].zero?
        FileUtils.rm(path, force: true)
        refs.delete(path)
      end
      IO.write(counts.path, serialize(refs))
    end
  end

  def synchronized
    File.open(COUNTS, File::CREAT | File::RDWR) do |f|
      f.flock(File::LOCK_EX)
      yield f
    end
  end

  def serialize(data)
    data.to_json
  end

  def deserialize(data)
    data.empty? ? {} : JSON.parse(data)
  rescue JSON::ParserError
    {}
  end
end
