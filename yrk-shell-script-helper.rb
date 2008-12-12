#!/usr/bin/env ruby -w

# A class to help make smart shell scripts using Ruby.
#
# Kelan Champagne
# http://yeahrightkeller.com
#
# Versions:
#   2008-11-??  v1.0  Initial public release

begin
    require 'rubygems'
rescue LoadError
end
require 'rdoc/usage'
require 'date'
require 'optparse'
require 'ostruct'
# require 'Timeout' # This was giving warnings about redefinition on Leopard

# to grab stderr from subprocesses (using popen3)
# from: http://ruby-doc.org/core/classes/Open3.html
# but, open3 has a bug in Ruby 1.8.5 (and apparently 1.8.6 on OS X 10.5) where it doesn't properly set $?, which I want to check for errors.  A workaround (which I learned here: http://tech.natemurray.com/2007/03/ruby-shell-commands.html ) is to use Open4, but, it's not installed everywhere.  So, I go through all this for now...
begin
  require 'open4'
  HASOPEN4 = true
rescue LoadError
  HASOPEN4 = false
end

require 'open3' # have this as a fallback


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# Utility Stuff

# Shell Colors
BLACK = "\033[0;30m"
BLUE = "\033[0;34m"
GREEN = "\033[0;32m"
CYAN = "\033[0;36m"
RED = "\033[0;31m"
PURPLE = "\033[0;35m"
BROWN = "\033[0;33m"
YELLOW = "\033[1;33m"
WHITE = "\033[1;37m"
NOCOLOR = "\033[00m"


# Output Decoration
CMD_COLOR = CYAN
CMD_PREFIX = "$ "
SKIPPED_CMD_COLOR = BLUE
SKIPPED_CMD_PREFIX = "# $ "
ECHO_COLOR = YELLOW
ECHO_PREFIX = "# "
HEADER_COLOR = GREEN
HEADER_PREFIX = "### "
HEADER_SUFFIX = " ###"
ERROR_PREFIX = "! "
ERROR_COLOR = RED
PROMPT_COLOR = PURPLE


# Add Dates as a new option type
# from Pickaxe, pg 711
# But slightly changed because I like dates like 2008-11-01
OptionParser.accept(Date, /(\d+)-(\d+)-(\d+)/) do |d, year, mon, day|
  Date.new(year.to_i, mon.to_i, day.to_i)
end


# Some Exceptions we might need to raise
class CommandError < Exception
end

class ArgumentsNotValid < Exception
end

class AbortCommand < Interrupt
end
class AbortSection < Interrupt
end
class AbortScript < Interrupt
end


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

class YRKShellScript

  attr_reader :op, :opts, :arguments, :stdin

  def initialize
    @arguments = ARGV
    if STDIN.stat.size?
      @stdin = STDIN.read
    else
      @stdin = ""
    end
    
    # Blocks that clients may provide
    @check_arguments_block = nil
    @add_options_block = nil
    @set_options_default_values_block = nil
    @process_stdin_block = nil
    
    # A place to stash default values
    @opts = OpenStruct.new
    
    # Standard options
    @op = OptionParser.new
    @op.summary_indent = "  "
    @op.summary_width = 25
    @op.on('-h', '-?', '--help',
      "Show this help") do
      output_help
    end
    
    @op.separator ""
    
    @op.on('--dry-run',
      "Only show the commands that would be run, don't actually run them") do
      @opts.dry_run = true
    end
    
    @op.on('-i', '--interactive',
      "Ask for confirmation before running each command.") do
      @opts.interactive = true
    end
    
    @op.on('--time',
      "Show before, after, and elapsed time") do
       @opts.show_times = true
    end
    
    @op.separator ""
    
    @op.on('-c', '--continue-on-error',
      "Stop if any command returns a non-zero exit status") do
      @opts.continue_on_error = true
    end
    
    @op.on('-C', '--stop-on-error',
      "Continue even if commands return non-zero exit status") do
      @opts.continue_on_error = false 
    end
    
    @op.separator ""
    @op.separator "Output Control:"
    
    @op.on('--debug',
      "Same as --verbosity=debug") do
      @opts.verbosity = :debug 
    end
    @op.on('--verbose',
      "Same as --verbosity=all") do
      @opts.verbosity = :all 
    end
    @op.on('--silent',
      "Same as --verbosity=silent") do
       @opts.verbosity = :silent
    end
    @op.on('-vLEVEL','--verbosity=LEVEL', String,
      %{Control the level of output.
                  Options are:
                    (5) debug:  Show evertying, including start/stop elapsed time
                                and also show the list of parsed options.
                    (4) all:    Show output from commands.  This is the default.
                    (3) cmds:   Show the commands as they are run, but not their output.
                    (2) echos:  Show #headers and #echos from the script.
                    (1) errors: Only show errors.
                    (0) silent: Show nothing.
                  Notes:
                    * higher levels also show everything below them
                    * use like: -v3 or --verbosity=cmds}) do |level|
      if ["debug", "5"].include? level
        @opts.verbosity = :debug
      elsif ["all", "4"].include? level
        @opts.verbosity = :all
      elsif ["cmds", "3"].include? level
        @opts.verbosity = :cmds
      elsif ["echos", "2"].include? level
        @opts.verbosity = :echos
      elsif ["errors", "1"].include? level
        @opts.verbosity = :errors
      elsif ["silent", "0"].include? level
        @opts.verbosity = :silent
      else
        @opts.show_errors = true # so our error output actually shows up
        error "\nInvalid verbosity level: #{level}\n"
        output_help(:options)
      end
    end

  end # initialize


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# Client scripts can call these methods, passing a block, in which they
# can access the attr_readers to get at script values
# We just remember the block to be called later, by #run

  # Call this to set the default values for any options
  # Examples:
  # script.op.on('-d') { do_something } # does this now, if the flag is given
  # script.op.on('-a', '--at DATE', Date) { |val| puts "Date: #{val}" }
  def add_options(&body)
    @add_options_block = body
  end
  
  # Call this to set the default values for any options
  # Examples:
  # script.opts.continue_on_error = true
  # script.opts.verbosity = :errors
  def set_options_default_values(&body)
    @set_options_default_values_block = body
  end
  
  # Call this to do argument validation
  # raise the ArgumentsNotValid exception to signal that there is a problem
  # You can include an optional error message as a 2nd argument to raise
  # Examples:
  # if script.arguments.length == 0
  #   raise ArgumentsNotValid, "Some error message"
  # end
  def check_arguments(&body)
    @check_arguments_block = body
  end

  # Call this to process any standard input text
  # Examples:
  # input = script.stdin
  # OR
  # script.stdin.each_line do |line|
  #   # process each line here
  # end
  def process_stdin(&body)
    @process_stdin_block = body
  end


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# This is the main body of the script, called by clients, and it does
# the steps in the passed block

  def run(&body)
    
    # Let client scripts add options
    if @add_options_block != nil
      @op.separator ""
      @op.separator "Custom Options:"
      @add_options_block.call 
    end
    
    # Set options default values
    @opts.verbosity = :all
    @opts.dry_run = false
    @opts.continue_on_error = false
    @opts.show_times = false
    
    # Let client scripts override options default values
    @set_options_default_values_block.call if @set_options_default_values_block != nil
    
    # Let clients process stdin, if they want
    @process_stdin_block.call if @process_stdin_block != nil
    
    
    # Setup signal handling
    
    # CTRL-C: skip the section, if you're in one.  otherwise skip the current command
    $sectionDepth = 0 # FIXME: is ther a better way than using this global counter?
    trap("SIGINT") do
      if $sectionDepth == 0
        raise(AbortCommand, "")
      else
        raise(AbortSection, "")
      end
    end
    
    # CTRL-\: Exit the whole script
    trap("SIGQUIT") { raise(AbortScript, "") }
    
    begin
      parse_options
      @check_arguments_block.call if @check_arguments_block != nil
    rescue ArgumentsNotValid => e
      error "\nArguments not valid: #{e.message}\n"
      output_help(:usage, :options)
    else
      if @opts.show_debug
        output_options
      end
      
      if @opts.show_times
        startTime = Time.now
        header "Start at #{startTime.to_s}"
        puts
      end

      begin
        body.call
      rescue AbortScript
        echo "\n\nUser aborted the script (by pressing CTRL-\\).\n"
      rescue CommandError => e
        error "\nScript aborted because this command failed:\n$ #{e.message}\n"
      end

      if @opts.show_times
        endTime = Time.now
        header "Finish at #{endTime.to_s}"
        header "Ran for #{(endTime - startTime).to_s} seconds"
      end
    end
  end # run


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
# Helper Tasks
# These are the steps you can call in the block you pass to #run

  def section(sectionName="", &sectionBody)
    header sectionName if sectionName != ""
    
    $sectionDepth += 1
    
    begin
      sectionBody.call
    rescue AbortSection
      echo "\nAborting section: #{sectionName} (user presseed CTRL-C)"
    rescue CommandError
      error "\nA command had non-zero exit value in section: #{sectionName}"
    else
      echo "Done with #{sectionName}"
    end

    $sectionDepth -= 1
  end # section

  def header(str="")
    if @opts.show_headers
      if str == nil or str == "" or str == "\n"
        puts
      else
        puts "\n"
        lines = str.split(/\n/, -1)
        longest_line = 0
        lines.each { |l| longest_line = l.size if l.size>longest_line }
        lines.each do |line|
          if line == ""
            puts
          else
            padding = ' ' * (longest_line - line.size)
            puts "#{HEADER_COLOR}#{HEADER_PREFIX}#{line}#{padding}#{HEADER_SUFFIX}#{NOCOLOR}\n"
          end
        end
      end
    end
  end # header

  def echo(str="")
    if @opts.show_echos
      if str == nil or str == "" or str == "\n"
        puts
      else
        str.split(/\n/, -1).each do |line|
          if line == ""
            puts
          else
            puts "#{ECHO_COLOR}#{ECHO_PREFIX}#{line}#{NOCOLOR}\n"
          end
        end
      end
    end
  end # echo

  def error(str="")
    if @opts.show_errors
      if str == nil or str == "" or str == "\n"
        puts
      else
        str.split(/\n/, -1).each do |line|
          if line == ""
            puts
          else
            puts "#{ERROR_COLOR}#{ERROR_PREFIX}#{line}#{NOCOLOR}"
          end
        end
      end
    end
  end # error

  def cd(str="~")
    if @opts.show_cmd
      puts "#{CMD_COLOR}#{CMD_PREFIX}cd #{str}#{NOCOLOR}"
    end
    
    # Do it even if test-only, because cd'ing doesn't hurt, and is probably
    # necessary to test the rest of the script
    Dir.chdir(str)
  end # cd
  
  # A convenience method for getting the output of a command without
  # showing the command or its output
  def cmd_output(str, params={})
    params[:capture_output] = true
    params[:show_cmd_output] = false unless params.has_key? :show_cmd_output
    params[:show_cmd] = false unless params.has_key? :show_cmd
    params[:force] = true unless params.has_key? :force
    
    output, status = cmd(str, params)
    return output
  end # def cmd_output
  
  # A convenience method for getting the exit status of a command without
  # showing the command or its output
  def cmd_status(str, params={})
    params[:capture_output] = true
    params[:show_cmd_output] = false unless params.has_key? :show_cmd_output
    params[:show_cmd] = false unless params.has_key? :show_cmd
    params[:force] = true unless params.has_key? :force
    params[:ignore_nonzero_exit] = true unless params.has_key? :ignore_nonzero_exit
    
    output, status = cmd(str, params)
    
    return status
  end # def cmd_status
  
  def cmd(str, params={})
    # Params hash can set parameters for this command only (including overriding the
    # global output control settings)
    skip = params[:skip] || false      # skip this command entirely
    force = params[:force] || false     # if true, run this command despite any --test flags

    if params.has_key? :capture_output
      capture_output = params[:capture_output]
    else
      capture_output = !@opts.show_cmd_output
    end
    
    if params.has_key? :show_cmd and !@opts.show_debug
      show_cmd = params[:show_cmd]
    else
      show_cmd = @opts.show_cmd
    end
    
    if params.has_key? :show_cmd_output and !@opts.show_debug
      show_cmd_output = params[:show_cmd_output]
    else
      show_cmd_output = @opts.show_cmd_output
    end
    
    if params.has_key? :continue_on_error
      continue_on_error = params[:continue_on_error]
    else
      continue_on_error = @opts.continue_on_error
    end
    
    if params.has_key? :show_errors
      show_errors = params[:show_errors]
    else
      show_errors = @opts.show_errors
    end
    
    if params.has_key? :ignore_nonzero_exit
      show_errors = !params[:ignore_nonzero_exit]
      continue_on_error = params[:ignore_nonzero_exit]
    end
    
    # TODO: the silent param can only force silence.  I.e. if you say :silent => false, that doesn't do anything.  Is this OK?
    if params[:silent]
      show_cmd = false
      show_cmd_output = false
    end
    
    # In interactive mode, ask before each command
    if (@opts.interactive)
      response = '?'
      while response == '?'
        response = get_input("Run? #{CYAN}$ #{str}", ["y", "n", "a", "q", "d", "?"])
        case response
        when 'n' # Skip this command
          skip = true
        when 'a' # Do the rest without asking
          @opts.interactive = false
        when 'd' # Do the rest as a dry-run
          @opts.interactive = false
          @opts.dry_run = true
        when 'q' # Quit
          exit 0
        when '?' # Show mini-help
          echo %{ Y  Yes       Run this command (default)
 n  No        Don't run this command
 a  All       Run this and the rest of the script without asking
 d  Dry-Run   Run the rest of the script as a dry-run
 q  Quit      Stop the script
 ?  Help      Show this help}
        end
      end
    end
    
    # Echo the command to be run
    if (show_cmd)
      if (skip)
        # print the cmd out in a way to show we skipped it
        puts "#{SKIPPED_CMD_COLOR}#{SKIPPED_CMD_PREFIX}#{str}#{NOCOLOR}"
      else
        # print out the cmd
        puts "#{CMD_COLOR}#{CMD_PREFIX}#{str}#{NOCOLOR}"
      end
    end
    
    # Now actually run the command
    begin
      if (!@opts.dry_run or force) and !skip
        if capture_output
          # Need Open4#popen4 or Open3#popen3 to launch child process and capture
          # the output without echoing it to the shell, and capture the stderr too
          if HASOPEN4
            # Use Open4#popen4, because it lets us get the exit status
            status, stdout, stderr = run_cmd_using_popen4(str)
          else
            # unfortunately open4 isn't commonly installed, so fall back on open3
            status, stdout, stderr = run_cmd_using_popen3(str)
          end
        else
          # If we don't need to capture/suppress output, just use system
          # as a benefit, this shows the output as it happens (instead of holding
          # it all until the end, which happens when we capture the output)
          status, stdout, stderr = run_cmd_using_system(str)
        end
        
        # Handle errors
        unless status == 0
          if show_errors
            error "Command ($ #{str}) failed with code: #{status.to_s}"
            error "stdout:\n#{stdout}" if stdout.size > 0
            error "stderr:\n#{stderr}" if stderr.size > 0
          end
          raise(CommandError, str) unless continue_on_error
        end
        # Now show the cmd output if necessary
        puts stdout if capture_output and show_cmd_output
      end
    rescue AbortCommand
      echo "\n\nAborted Command: #{str} (user pressed CTRL-C)"
    end
    if stdout
      return stdout.chomp, status
    else
      return "", status
    end
  end # cmd
  
  # Helpers for #cmd
  
  def run_cmd_using_popen4(str)
    output = error_output = ""
    begin
      status = Open4::popen4(str) do |pid, stdin, stdout, stderr|
        output = stdout.read
        error_output = stderr.read
      end
    rescue => e
      # This happens if the command cannot be found
      status = 460
      error_output = e.to_s
    end
    return status, output, error_output
  end # run_cmd_using_popen4
  
  def run_cmd_using_popen3(str)
    stdin, stdout, stderr = Open3.popen3(str)
    return $?, stdout.read, stderr.read
  end
  
  def run_cmd_using_system(str)
    system(str)
    return $?, "", "" # stdout was written out directly, nothing to return
  end
  
  # Prompt the user for input, optiontally timing out
  # for now, by convention, the default option is the first one
  # also, for now, options are single chars only
  # TODO: parse the accepted_input, figure out the default, etc.
  def get_input(prompt, accepted_input=[], timeout=0, params={})
    accepted_input.first.upcase!
    valid_input = false
    until valid_input
      print "#{ECHO_COLOR}#{prompt}"
      print " (timeout in #{timeout} secs.)" if timeout > 0
      print "#{PROMPT_COLOR}\n[#{accepted_input.join('/')}]? #{NOCOLOR}"
      STDOUT.flush
      input = ""
      if timeout > 0
        begin
          Timeout::timeout(timeout) do
            input = STDIN.gets.chomp
          end
        rescue Timeout::Error
          input = ''
          valid_input = true
          echo "Timed out.  Using default value: #{input}" # TODO this doesn't actually show what that default value is
        end
      else
        input = STDIN.gets.chomp
      end
      if input == ''
        valid_input = true
        input = accepted_input.first # TODO: make this a better default
      elsif accepted_input.detect {|i| i.downcase == input.downcase}
        valid_input = true
      else
        error "Invalid input: #{input}"
        echo "Enter one of: #{accepted_input.join(', ')}"
      end
    end
    puts # go to new line
    return input
  end # get_input

  # For scripts that are intended for OS X only, you can just say:
  #   script.requires_MacOSX
  # TODO: this could be extended to other platforms, but suits my needs for now
  def requires_MacOSX
    unless "darwin" == cmd_output("echo ${OSTYPE:0:6}")
      @opts.show_errors = true # so our error output actually shows up
      error "This script requires Mac OS X."
      exit 1
    end
  end

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
  protected

  def parse_options
    begin
      # parse the options (via OptionParser), and keep the actual args in @arguments
      @arguments = @op.parse(@arguments)
    rescue => e
      error "\nError parsing options: #{e.message}"
    end
    
    # Perform post-parse processing on options
    
    if @opts.dry_run
      @opts.verbosity = :all
    end
    
    # Set up Output Control
    case @opts.verbosity
    when :debug
      @opts.show_debug = true
      @opts.show_cmd_output = true
      @opts.show_cmd = true
      @opts.show_echos = @opts.show_headers = true
      @opts.show_errors = @opts.show_cmd_erros = true
      
      @opts.show_times = true
    when :all
      @opts.show_debug = false
      @opts.show_cmd_output = true
      @opts.show_cmd = true
      @opts.show_echos = @opts.show_headers = true
      @opts.show_errors = @opts.show_cmd_erros = true
    when :cmds
      @opts.show_debug = false
      @opts.show_cmd_output = false
      @opts.show_cmd = true
      @opts.show_echos = @opts.show_headers = true
      @opts.show_errors = @opts.show_cmd_erros = true
    when :echos
      @opts.show_debug = false
      @opts.show_cmd_output = false
      @opts.show_cmd = false
      @opts.show_echos = @opts.show_headers = true
      @opts.show_errors = @opts.show_cmd_erros = true
    when :errors
      @opts.show_debug = false
      @opts.show_cmd_output = false
      @opts.show_cmd = false
      @opts.show_echos = @opts.show_headers = false
      @opts.show_errors = @opts.show_cmd_erros = true
    when :silent
      @opts.show_debug = false
      @opts.show_cmd_output = false
      @opts.show_cmd = false
      @opts.show_echos = @opts.show_headers = false
      @opts.show_errors = @opts.show_cmd_erros = false
    end
  end # parse_options
  
  def output_options
    puts "Options:"
    @opts.marshal_dump.each do |name, val|
      puts "  #{name} = #{val}"
    end
  end

  def output_help(*args)
    if args.size == 0
      RDoc::usage_no_exit()
    elsif args.include? :usage
      RDoc::usage_no_exit("Usage")
    end
    if args.include? :options or args.size == 0
      puts "Options", "-------", @op.summarize
    end
    exit 0
  end

end # class YRKShellScript
