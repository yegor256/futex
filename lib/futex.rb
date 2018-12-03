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

require 'fileutils'
require 'time'

# Futex (file mutex) is a fine-grained mutex that uses a file, not an entire
# thread, like <tt>Mutex</tt> does. Use it like this:
#
#  require 'futex'
#  Futex.new('/tmp/my-file.txt').open |f|
#    IO.write(f, 'Hello, world!')
#  end
#
# The file <tt>/tmp/my-file.txt.lock<tt> will be created and
# used as an entrance lock.
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
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
class Futex
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

  # Open the file.
  def open(exclusive = true)
    FileUtils.mkdir_p(File.dirname(@lock))
    step = (1 / @sleep).to_i
    start = Time.now
    prefix = exclusive ? '' : 'non-'
    b = badge(exclusive)
    File.open(@lock, File::CREAT | File::RDWR) do |f|
      cycle = 0
      loop do
        if f.flock((exclusive ? File::LOCK_EX : File::LOCK_SH) | File::LOCK_NB)
          break
        end
        sleep(@sleep)
        cycle += 1
        Thread.current.thread_variable_set(:futex_cycle, cycle)
        Thread.current.thread_variable_set(:futex_time, Time.now - start)
        if Time.now - start > @timeout
          raise "#{b} can't get #{prefix}exclusive access \
to the file #{@path} because of the lock at #{@lock}, after #{age(start)} \
of waiting: #{IO.read(@lock)}"
        end
        if (cycle % step).zero? && Time.now - start > @timeout / 2
          debug("#{b} still waiting for #{prefix}exclusive
access to #{@path}, #{age(start)} already: #{IO.read(@lock)}")
        end
      end
      debug("Locked by #{b} in #{age(start)}, #{prefix}exclusive: \
#{@path} (attempt no.#{cycle})")
      File.write(@lock, b)
      acq = Time.now
      res = yield(@path)
      debug("Unlocked by #{b} in #{age(acq)}, #{prefix}exclusive: #{@path}")
      res
    end
  end

  private

  def badge(exclusive)
    tname = Thread.current.name
    tname = 'nil' if tname.nil?
    "##{Process.pid}-#{exclusive ? 'ex' : 'sh'}/#{tname}"
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
end
