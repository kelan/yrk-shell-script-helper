#!/usr/bin/env ruby -w

# == Synopsis
#   This is a script to test and demonstrate my YRKShellScript helper class
#
# == Usage
#   demo-shell-script [options] arg1
#
# == Examples
#   Run normally:
#     $ demo-shell-script
#
#   Show each command it executes:
#     $ demo-shell-script --verbose
#
#   Show the commands it would execute, but don't actually execute:
#     $ demo-shell-script --test
#
#   Show commands and other debugging output:
#     $ demo-shell-script --debug

require 'yrk-shell-script-helper.rb'

script = YRKShellScript.new

# Define a method to be called by an option
# NOTE: you have to pass script as an arg if you want to do script.echo or script.cmd, etc.
def printEs(script)
  script.echo "EEEEE"
end

# Add additional options
script.add_options do
  # NOTE: The code you run in one of these blocks gets run immediately (before even the option are finished parsing), so be careful.  I usually just set a flag or value in the script.opts OpenStruct, which is used later in the body of the script.  Also note that if you call a method here (such as #printEs) you have to pass script as an arg in order to have access to it there (for doing script.echo or script.cmd, etc.).
  script.op.on('-d', "Set the doSomething flag") { script.opts.doSomething = true }
  script.op.on('-e', "Print EEEEE" ) { printEs(script) }
  script.op.on('-a', '--at DATE', Date, "set a date") do |val|
    script.opts.date = val
  end
end

# Set default values for any optoins we add, or if we want
# to override the defaults from yrk-shell-script-helper.rb
script.set_options_default_values do
  script.opts.continue_on_error = false
  script.opts.verbosity = :all
  script.opts.doSomething = false
end

# Do argument validation
# raise OptionParser::InvalidArgument or OptionParser::MissingArgument
# (with an optional message) if args aren't valid or missing (respectively)
script.check_arguments do
  script.echo "Checking if args are valid"
  if script.opts.debug
    script.echo "there are #{script.arguments.length} args (not including options)"
  end

  script.echo "overriding an option"
  script.opts.show_errors = true
  
  if script.arguments.length == 0
    raise OptionParser::MissingArgument, "Need at least 1 argument"
  end
end


# Here is the body of the script
script.run do
  
  if script.opts.doSomething
    script.echo "I'm doing something"
  end
  
  # check if they passed the date option flag (and value)
  if script.opts.date != nil
    script.echo "You passed date=#{script.opts.date}"
  end
  
  # Section help you divide the script into sections
  # * they print out their title in green, with extra line-breaks
  # * also, if you do ctrl-C during the script, it just ends that section

  script.section "Testing cd" do
    # This doesn't work, because each cmd gets its own system() call
    script.cmd "cd /"
    script.cmd "pwd"

    # This does what it says, but still doesn't stay in the new dir
    script.cmd "cd /Users; pwd"
    script.cmd "pwd"

    # This is the proper way to change dirs
    script.cd "/"
    script.cmd "pwd"
  end
  
  script.echo "The following command will stop the script unless you do --continue-on-error"
  script.cmd "false"
  
  script.section "Testing the ENV" do
    # Unfortunately, we dont' inherit the ENV from the users' shell...
    script.cmd "alias | wc -l"

    # This sourcing doesn't want to work, but we can set to continue on errors
    script.cmd "source ~/.profile", :continue_on_error => true, :capture_output => true
    script.cmd "alias | wc -l"
  end
  
  script.section "More Stuff" do
    # We can also conditionally skip a command
    script.cmd "sleep 10", :skip => (3 < 5)

    # We can also query the opts from here (but they're read-only)
    if script.opts.debug
      script.echo "In debug mode" 
    else
      script.echo "Not in debug mode"
    end

    script.echo "Here is an echo with multiple lines.\nEach line gets prepended with the comment marker.\nBut blank lines stay blank, see:\n\nEven with more text below."
    
  end
  
  # To get the output of a command, use the #cmd_output method
  # This is just a convenience method for calling #cmd with :capture_output => true
  # NOTE: Obivously, this won't return until the cmd is finished, but also it won't
  # print any output to the console (when you pass :show_cmd_output => true) until
  # the entire command has finished.
  ls = script.cmd_output "ls"
  script.echo "ls.size = #{ls.size}"
  
  # often want to :force this command even in --test mode because it is used to determine flow
  script.cd "#{ENV['HOME']}/nix"
  currentBranch = script.cmd_output "git branch | awk '/^\\*/ {print \$2}'"

  # We can do ruby code/logic during the script
  if (currentBranch != "")
    script.echo "current branch = #{currentBranch}"
  else
    # The error() method just prints out the string in red
    script.error "couldn't get git branch"
  end

  # There is a helper to get user input
  # Right now it just accepts single-character responses, but it does have an
  # optional timeout, in which case it uses the default response (which, by convention is the
  # first one listed in the array of accepted responses)
  script.section "Testing user input" do
    response = script.get_input("Enter something.", ["y", "n"], 15)
    script.echo "you entered #{response}"
  end

  # We can also do the green header text without doing a full sction
  script.header "The End"

end
