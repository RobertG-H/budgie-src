require "rake"

module RakeHelpers
  # Invokes the task with ENV values (nil unsets one) and optional stdin, restoring both afterwards.
  # Returns what the task printed to stdout; a failing task raises SystemExit.
  def run_task(name, stdin: "", **env)
    Rails.application.load_tasks unless Rake::Task.task_defined?(name)

    previous_env = env.keys.index_with { |key| ENV[key] }
    env.each { |key, value| ENV[key] = value }
    original_stdin, original_stdout = $stdin, $stdout
    $stdin, $stdout = StringIO.new(stdin), StringIO.new

    Rake::Task[name].reenable
    Rake::Task[name].invoke
    $stdout.string
  ensure
    $stdin, $stdout = original_stdin, original_stdout
    previous_env.each { |key, value| ENV[key] = value }
  end

  def expect_task_failure(name, message, **options)
    expect { run_task(name, **options) }
      .to raise_error(SystemExit) { |exit| expect(exit.status).not_to eq(0) }
      .and output(message).to_stderr
  end
end

RSpec.configure do |config|
  config.include RakeHelpers, type: :task
end
