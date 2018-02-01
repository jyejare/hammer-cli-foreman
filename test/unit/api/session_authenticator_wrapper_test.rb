require File.join(File.dirname(__FILE__), '../test_helper')

describe HammerCLIForeman::Api::SessionAuthenticatorWrapper do

  let(:wrapped_auth) { mock() }
  let(:url) { 'http://foreman.example.com' }
  let(:args) { {} }
  let(:request) { Net::HTTP::Get.new(URI(url), {}) }

  def session_file(dir)
    "#{dir}/http_foreman.example.com"
  end

  def write_session(dir, content, permissions=nil)
    File.open(session_file(dir), 'w', permissions) do |f|
      f.write(content)
    end
  end

  def prepare_session_storage(options = {}, &block)
    options[:dir_permissions] ||= 0700
    options[:file_permissions] ||= 0600
    options[:user_name] ||= 'admin'

    out = err = ""

    dir = Dir.mktmpdir
    begin
      FileUtils.chmod(options[:dir_permissions], dir)

      if options[:session_id]
        session = JSON.dump({
          :session_id => options[:session_id],
          :user_name => options[:user_name]
        })
        write_session(dir, session, options[:file_permissions])
      end

      out, err = capture_io do
        auth = HammerCLIForeman::Api::SessionAuthenticatorWrapper.new(wrapped_auth, url, dir)
        yield(auth, dir) if block_given?
      end
    ensure
      FileUtils.remove_entry(dir)
    end

    return dir, out, err
  end

  describe '#initialize' do
    context "when there's saved session" do
      it 'warns when session directory has wrong permissions' do
        dir, out, err = prepare_session_storage :dir_permissions => 0744

        assert_match /Invalid permissions for #{dir}: 40744, expected 40700/, err
        assert_match /Can't use session auth due to invalid permissions on session files/, err
      end

      it 'warns when session file has wrong permissions' do
        dir, out, err = prepare_session_storage :session_id => 'SOME_SESSION_ID', :file_permissions => 0644

        assert_match /Invalid permissions for #{session_file(dir)}: 100644, expected 100600/, err
        assert_match /Can't use session auth due to invalid permissions on session files/, err
      end
    end
  end

  describe '#authenticate' do
    context "when there's saved session" do
      it 'sets session id in cookies' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          wrapped_auth.expects(:user).returns('admin')
          auth.authenticate(request, args)

          assert_equal "_session_id=SOME_SESSION_ID", request['Cookie']
        end
      end

      it 'ignores session when the session file has wrong permissions' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID', :file_permissions => 0644 do |auth, dir|
          wrapped_auth.expects(:authenticate).with(request, args)
          wrapped_auth.expects(:user).returns('admin')
          auth.authenticate(request, args)

          assert_nil request['Cookie']
        end
      end

      it 'ignores session when the directory has wrong permissions' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID', :dir_permissions => 0744 do |auth, dir|
          wrapped_auth.expects(:authenticate).with(request, args)
          wrapped_auth.expects(:user).returns('admin')
          auth.authenticate(request, args)

          assert_nil request['Cookie']
        end
      end

      it "keeps the session and sets cuser_changed flag when usernames don't match and " do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          wrapped_auth.expects(:authenticate).with(request, args)
          wrapped_auth.expects(:user).returns('other_user')
          auth.authenticate(request, args)

          assert File.exist?(session_file(dir))
          assert auth.user_changed?
        end
      end

      it "keeps the session when username is nil" do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          wrapped_auth.expects(:user).returns(nil)
          auth.authenticate(request, args)

          assert_equal "_session_id=SOME_SESSION_ID", request['Cookie']
          assert File.exist?(session_file(dir))
        end
      end
    end

    context "when the session file is corrupted" do
      it 'reports error' do
        dir, out, err = prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          write_session(dir, '{not a valid: json')

          wrapped_auth.expects(:authenticate).with(request, args)
          wrapped_auth.expects(:user).returns('admin')
          auth.authenticate(request, args)
        end

        assert_match /Invalid session file format/, err
      end

      it 'deletes the session file' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          write_session(dir, '{not a valid: json')

          wrapped_auth.expects(:authenticate).with(request, args)
          wrapped_auth.expects(:user).returns('admin')
          auth.authenticate(request, args)

          refute File.exist?(session_file(dir))
        end
      end
    end

    context "when no session is saved" do
      it 'passes to wrapped authenticator' do
        prepare_session_storage do |auth, dir|
          wrapped_auth.expects(:authenticate).with(request, args)
          wrapped_auth.expects(:user).returns('admin')
          auth.authenticate(request, args)
        end
      end
    end
  end

  describe '#error' do
    context 'when there is existing session' do
      it 'deletes saved session on unauthorized exception' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          ex = RestClient::Unauthorized.new

          auth.error(ex)

          refute File.exist?(session_file(dir))
        end
      end

      it 'overrides 401 exception' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          ex = RestClient::Unauthorized.new
          new_ex = auth.error(ex)

          assert_equal 'Session has expired.', new_ex.message
        end
      end

      it 'does not override other exceptions' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          ex = RuntimeError.new('Some error')
          wrapped_auth.expects(:error).with(ex)
          new_ex = auth.error(ex)

          assert_nil new_ex
        end
      end

      it 'keeps session for other exceptions' do
        prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
          ex = RuntimeError.new('Some error')
          wrapped_auth.expects(:error).with(ex)
          auth.error(ex)

          assert File.exist?(session_file(dir))
        end
      end

      context 'when user has changed' do
        it 'sets a special error message' do
          prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
            auth.force_user_change
            ex = RestClient::Unauthorized.new
            new_ex = auth.error(ex)

            assert_equal "Invalid username or password, continuing with session for 'admin'.", new_ex.message
          end
        end

        it 'keeps the previous session' do
          prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
            auth.force_user_change
            ex = RestClient::Unauthorized.new
            auth.error(ex)

            assert File.exist?(session_file(dir))
          end
        end
      end
    end

    context 'when there is no existing session' do
      it 'passes exception to wrapped authenticator on unauthorized exception' do
        prepare_session_storage do |auth, dir|
          ex = RestClient::Unauthorized.new

          wrapped_auth.expects(:error).with(ex).returns(:new_exception)
          assert_equal(:new_exception, auth.error(ex))
        end
      end

      it 'keeps error message for other exceptions' do
        prepare_session_storage do |auth, dir|
          ex = RuntimeError.new('Some error')
          wrapped_auth.expects(:error).with(ex).returns(ex)
          new_ex = auth.error(ex)

          assert_equal 'Some error', new_ex.message
        end
      end
    end
  end

  describe '#response' do
    it "saves session id if it's in response cookies" do
      prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
        resp = stub(:cookies => {'_session_id' => 'NEW_SESSION_ID'}, :code => 200)

        wrapped_auth.expects(:response).with(resp)
        wrapped_auth.expects(:user).returns('admin')
        auth.response(resp)

        session = JSON.parse(File.read(session_file(dir)))

        assert_equal 'NEW_SESSION_ID', session['session_id']
      end
    end

    it "saves username" do
      prepare_session_storage do |auth, dir|
        resp = stub(:cookies => {'_session_id' => 'NEW_SESSION_ID'}, :code => 200)

        wrapped_auth.expects(:response).with(resp)
        wrapped_auth.expects(:user).returns('admin')
        auth.response(resp)

        session = JSON.parse(File.read(session_file(dir)))

        assert_equal 'admin', session['user_name']
      end
    end

    it "ignores requests without session cookie" do
      prepare_session_storage do |auth, dir|
        resp = stub(:cookies => {}, :code => 200)

        wrapped_auth.expects(:response).with(resp)
        auth.response(resp)

        refute File.exist?(session_file(dir))
      end
    end

    it "ignores unauthorized requests" do
      prepare_session_storage do |auth, dir|
        resp = stub(:cookies => {'_session_id' => 'NEW_SESSION_ID'}, :code => 401)

        wrapped_auth.expects(:response).with(resp)
        auth.response(resp)

        refute File.exist?(session_file(dir))
        assert_nil auth.session_id
      end
    end
  end

  describe '#user' do
    it "returns nil when wrapped authenticator doesn't respond to #user" do
      prepare_session_storage do |auth, dir|
        assert_nil auth.user
      end
    end

    it "calls #user on the wrapped authentocator" do
      prepare_session_storage do |auth, dir|
        wrapped_auth.expects(:user).returns('admin')
        assert_equal 'admin', auth.user
      end
    end
  end

  describe '#user_changed?' do
    it 'is false by default' do
      prepare_session_storage do |auth, dir|
        refute auth.user_changed?
      end
    end
  end

  describe '#force_user_change' do
    it 'sets force user change flag' do
      prepare_session_storage do |auth, dir|
        auth.force_user_change
        assert auth.user_changed?
      end
    end
  end

  describe '#set_credentials' do
    it 'passes credentials to a wrapped authenticator' do
      prepare_session_storage do |auth, dir|
        wrapped_auth.expects(:set_credentials).with('admin', 'password')
        auth.set_credentials('admin', 'password')
      end
    end

    it "doesn't pass the credentials when a wrapped autneticator doesn't support it" do
      prepare_session_storage do |auth, dir|
        auth.set_credentials('admin', 'password')
      end
    end
  end

  describe '#clear' do
    it 'passes clear to a wrapped authenticator' do
      prepare_session_storage do |auth, dir|
        wrapped_auth.expects(:clear)
        auth.clear
      end
    end

    it "doesn't pass clear when a wrapped autneticator doesn't support it" do
      prepare_session_storage do |auth, dir|
        auth.clear
      end
    end
  end

  describe '#status' do
    it 'informs that there is no existing session' do
      prepare_session_storage do |auth, dir|
        assert_equal "Using sessions, you are currently not logged in.", auth.status
      end
    end

    it "informas about existing session" do
      prepare_session_storage :session_id => 'SOME_SESSION_ID' do |auth, dir|
        assert_equal "Session exists, currently logged in as 'admin'.", auth.status
      end
    end
  end
end
