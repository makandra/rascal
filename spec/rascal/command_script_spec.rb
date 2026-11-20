module Rascal
  describe CommandScript do

    def script(command = 'rake', **options)
      described_class.new(command, working_dir: '/repo', **options).to_s
    end

    def lines(script)
      script.split("\n")
    end

    it 'runs before_shell, the command and after_shell on separate lines, and exits with the status of the command' do
      expect(lines(script(before_shell: ['Xvfb :99 &', 'bundle check # quietly'], after_shell: ['echo done']))).to match [
        a_string_including('safe.directory /repo'),
        'Xvfb :99 &',
        'bundle check # quietly',
        'rake',
        '__rascal_status=$?',
        'echo done',
        'exit $__rascal_status',
      ]
    end

    it 'first waits for each service with ports, as long as wait_timeout says' do
      script = script(waits: [['db', [5432, 33060]], ['no-ports', []], ['redis', [6379]]], wait_timeout: 120)

      expect(lines(script).first(3)).to eq [
        CommandScript::WAIT_FOR_FUNCTION,
        '__rascal_wait_for db 120 5432 33060',
        '__rascal_wait_for redis 120 6379',
      ]
    end

    it "lets Git trust the project, in the container's global config, once" do
      expect(script).to start_with(
        'if command -v git > /dev/null 2>&1 && ! git config --global --get-all safe.directory 2> /dev/null | grep -qxF /repo; ' \
        "then git config --global --add safe.directory /repo 2> /dev/null; fi\n"
      )
    end

    it 'gives files root created in the project to the owner, if the project appears as theirs' do
      expect(lines(script(owner: [1000, 1001]))[-2]).to eq(
        '[ "$(stat -c %u /repo 2>/dev/null)" = 1000 ] && find /repo -xdev -user 0 -exec chown -h 1000:1001 {} + 2>/dev/null'
      )
      expect(script).not_to include('chown')
    end

  end
end
