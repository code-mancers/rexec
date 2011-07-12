# Copyright (c) 2007, 2011 Samuel G. D. Williams. <http://www.oriontransfer.co.nz>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
class String
  # Helper for turning a string into a shell argument
  def to_arg
    match(/\s/) ? dump : self
  end
  
  def to_cmd
    return self
  end
end

class Array
  # Helper for turning an array of items into a command line string
  # <tt>["ls", "-la", "/My Path"].to_cmd => "ls -la \"/My Path\""</tt>
  def to_cmd
    collect{ |a| a.to_arg }.join(" ")
  end
end

class Pathname
  # Helper for turning a pathname into a command line string
  def to_cmd
    to_s
  end
end

module RExec
  RD = 0
  WR = 1

  # This function closes all IO other than $stdin, $stdout, $stderr
  def self.close_io(except = [$stdin, $stdout, $stderr])
    # Make sure all file descriptors are closed
    ObjectSpace.each_object(IO) do |io|
      unless except.include?(io)
        io.close rescue nil
      end
    end
  end

  class Task
    private
    def self.pipes_for_options(options)
      pipes = [[nil, nil], [nil, nil], [nil, nil]]

      if options[:passthrough]
        passthrough = options[:passthrough]
        
        if passthrough == :all
          passthrough = [:in, :out, :err]
        elsif passthrough.kind_of?(Symbol)
          passthrough = [passthrough]
        end
        
        passthrough.each do |name|
          case(name)
          when :in
            options[:in] = $stdin
          when :out
            options[:out] = $stdout
          when :err
            options[:err] = $stderr
          end
        end
      end
      
      modes = [RD, WR, WR]
      {:in => 0, :out => 1, :err => 2}.each do |name, idx|
        m = modes[idx]
        p = options[name]
        
        if p.kind_of?(IO)
          pipes[idx][m] = p
        elsif p.kind_of?(Array) and p.size == 2
          pipes[idx] = p
        else
          pipes[idx] = IO.pipe
        end
      end

      return pipes
    end
    
    # Close all the supplied pipes
    def close_pipes(*pipes)
      pipes.compact!

      pipes.each do |pipe|
        pipe.close unless pipe.closed?
      end
    end

    # Dump any remaining data from the pipes, until they are closed.
    def dump_pipes(*pipes)
      pipes.compact!

      pipes.delete_if { |pipe| pipe.closed? }
      # Dump any output that was not consumed (errors, etc)
      while pipes.size > 0
        result = IO.select(pipes)

        result[0].each do |pipe|
          if pipe.closed? || pipe.eof?
            pipes.delete(pipe)
            next
          end

          $stderr.puts pipe.readline.chomp
        end
      end
    end
    
    public
    # Returns true if the given pid is a current process
    def self.running?(pid)
      gpid = Process.getpgid(pid) rescue nil

      return gpid != nil ? true : false
    end
    
    # Very simple method to spawn a child daemon. A daemon is detatched from the controlling tty, and thus is
    # not killed when the parent process finishes.
    # <tt>
    # spawn_daemon do
    #   Dir.chdir("/")
    #   File.umask 0000
    #   puts "Hello from daemon!"
    #   sleep(600)
    #   puts "This code will not quit when parent process finishes..."
    #   puts "...but $stdout might be closed unless you set it to a file."
    # end
    # </tt>
    def self.spawn_daemon(&block)
      pid_pipe = IO.pipe

      fork do
        Process.setsid
        exit if fork

        # Send the pid back to the parent
        pid_pipe[RD].close
        pid_pipe[WR].write(Process.pid.to_s)
        pid_pipe[WR].close

        yield

        exit(0)
      end

      pid_pipe[WR].close
      pid = pid_pipe[RD].read
      pid_pipe[RD].close

      return pid.to_i
    end
    
    # Very simple method to spawn a child process
    # <tt>
    # spawn_child do 
    #   puts "Hello from child!"
    # end
    # </tt>
    def self.spawn_child(&block)
      pid = fork do
        yield

        exit!(0)
      end

      return pid
    end
    
    # Open a process. Similar to IO.popen, but provides a much more generic interface to stdin, stdout, 
    # stderr and the pid. We also attempt to tidy up as much as possible given some kind of error or
    # exception. You are expected to write to output, and read from input and error.
    #
    # = Options =
    #
    # We can specify a pipe that will be redirected to the current processes pipe. A typical one is
    # :err, so that errors in the child process are printed directly to $stderr of the parent process.
    # <tt>:passthrough => :err</tt>
    # <tt>:passthrough => [:in, :out, :err]</tt> or <tt>:passthrough => :all</tt>
    #
    # We can specify a set of pipes other than the standard ones for redirecting to other things, eg
    # <tt>:out => File.open("output.log", "a")</tt>
    #
    # If you need to supply a pipe manually, you can do that too:
    # <tt>:in => IO.pipe</tt>
    #
    # You can specify <tt>:daemon => true</tt> to cause the child process to detatch. In this
    # case you will generally want to specify files for <tt>:in, :out, :err</tt> e.g.
    # <tt>
    #   :in => File.open("/dev/null"),
    #   :out => File.open("/var/log/my.log", "a"),
    #   :err => File.open("/var/log/my.err", "a")
    # </tt>
    def self.open(command, options = {}, &block)
      cin, cout, cerr = pipes_for_options(options)
      stdpipes = [STDIN, STDOUT, STDERR]

      spawn = options[:daemonize] ? :spawn_daemon : :spawn_child

      cid = self.send(spawn) do
        [cin[WR], cout[RD], cerr[RD]].compact.each { |pipe| pipe.close }
        
        STDIN.reopen(cin[RD]) if cin[RD] and !stdpipes.include?(cin[RD])
        STDOUT.reopen(cout[WR]) if cout[WR] and !stdpipes.include?(cout[WR])
        STDERR.reopen(cerr[WR]) if cerr[WR] and !stdpipes.include?(cerr[WR])
        
        if command.respond_to? :call
          command.call
        else
          # If command is a Pathname, we need to convert it to an absolute path if possible,
          # otherwise if it is relative it might cause problems.
          if command.respond_to? :realpath
            command = command.realpath
          end
          
          if command.respond_to? :to_cmd
            exec(command.to_cmd)
          else
            exec(command.to_s)
          end
        end
      end
      
      # Don't close stdin, stdout, stderr.
      [cin[RD], cout[WR], cerr[WR]].compact.each { |pipe| pipe.close unless stdpipes.include?(pipe) }

      task = Task.new(cin[WR], cout[RD], cerr[RD], cid)

      if block_given?
        begin
          yield task
          task.close_input
          return task.wait
        ensure
          task.stop
        end
      else
        return task
      end
    end
    
    def initialize(input, output, error, pid)
      @input = input
      @output = output
      @error = error
      
      @pid = pid
      @result = nil
    end
    
    attr :input
    attr :output
    attr :error
    attr :pid
    attr :result
    
    def running?
      return self.class.running?(@pid)
    end
    
    # Close all connections to the child process
    def close
      close_pipes(@input, @output, @error)
    end
    
    # Close input pipe to child process (if applicable)
    def close_input
      @input.close if @input and !@input.closed?
    end
    
    # Send a signal to the child process
    def kill(signal = "INT")
      Process.kill("INT", @pid)
    end
    
    # Wait for the child process to finish, return the exit status.
    def wait
      begin
        close_input
        
        _pid, @result = Process.wait2(@pid)
        
        dump_pipes(@output, @error)
      ensure
        close_pipes(@input, @output, @error)
      end
      
      return @result
    end
    
    # Forcefully stop the child process.
    def stop
      # The process has already been stoped/waited upon
      return if @result
      
      begin
        close_input
        kill
        wait
        
        dump_pipes(@output, @error)
      ensure
        close_pipes(@output, @error)
      end
    end
  end
end
