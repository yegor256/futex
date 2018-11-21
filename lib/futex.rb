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
    File.open(@lock, File::CREAT | File::RDWR) do |f|
      cycle = 0
      loop do
        if f.flock((exclusive ? File::LOCK_EX : File::LOCK_SH) | File::LOCK_NB)
          break
        end
        sleep(@sleep)
        cycle += 1
        if Time.now - start > @timeout
          raise "#{badge} can't get #{exclusive ? '' : 'non-'}exclusive access \
to the file #{@path} because of the lock at #{@lock}, after #{age(start)} \
of waiting: #{IO.read(@lock)}"
        end
        if (cycle % step).zero? && Time.now - start > @timeout / 2
          debug("#{badge} still waiting for #{exclusive ? '' : 'non-'}exclusive
access to #{@path}, #{age(start)} already: #{IO.read(@lock)}")
        end
      end
      debug("Locked by #{badge} in #{age(start)}: #{@path} \
(attempt no.#{cycle})")
      File.write(@lock, badge)
      acq = Time.now
      res = yield(@path)
      debug("Unlocked by #{badge} in #{age(acq)}: #{@path}")
      res
    end
  end

  private

  def badge
    tname = Thread.current.name
    tname = 'nil' if tname.nil?
    "##{Process.pid}/#{tname}"
  end

  def age(time)
    "#{((Time.now - time) * 1000).round}ms"
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
