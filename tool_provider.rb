require 'sinatra'
require 'ims/lti'
# must include the oauth proxy object
require 'oauth/request_proxy/rack_request'

enable :sessions
set :protection, :except => :frame_options

get '/' do
  erb :index
end

# the consumer keys/secrets
$oauth_creds = {"test" => "secret", "testing" => "supersecret"}

def show_error(message)
  @message = message
end

def authorize!
  if key = params['oauth_consumer_key']
    if secret = $oauth_creds[key]
      @tp = IMS::LTI::ToolProvider.new(key, secret, params)
    else
      @tp = IMS::LTI::ToolProvider.new(nil, nil, params)
      @tp.lti_msg = "Your consumer didn't use a recognized key."
      @tp.lti_errorlog = "You did it wrong!"
      show_error "Consumer key wasn't recognized"
      return false
    end
  else
    show_error "No consumer key"
    return false
  end

  if !@tp.valid_request?(request)
    show_error "The OAuth signature was invalid"
    return false
  end

  if Time.now.utc.to_i - @tp.request_oauth_timestamp.to_i > 60*60
    show_error "Your request is too old."
    return false
  end

  # this isn't actually checking anything like it should, just want people
  # implementing real tools to be aware they need to check the nonce
  if was_nonce_used_in_last_x_minutes?(@tp.request_oauth_nonce, 60)
    show_error "Why are you reusing the nonce?"
    return false
  end

  # save the launch parameters for use in later request
  session['launch_params'] = @tp.to_params

  @username = @tp.username("Dude")

  return true
end

# The url for launching the tool
# It will verify the OAuth signature
post '/lti_tool' do
  return erb :error unless authorize!

  if @tp.outcome_service?
    # It's a launch for grading
    erb :assessment
  else
    # normal tool launch without grade write-back
    signature = OAuth::Signature.build(request, :consumer_secret => @tp.consumer_secret)

    @signature_base_string = signature.signature_base_string
    @secret = signature.send(:secret)

    @tp.lti_msg = "Sorry that tool was so boring"
    erb :boring_tool
  end
end

post '/signature_test' do
  erb :proxy_setup
end

post '/proxy_launch' do
  uri = URI.parse(params['launch_url'])

  if uri.port == uri.default_port
    host = uri.host
  else
    host = "#{uri.host}:#{uri.port}"
  end

  consumer = OAuth::Consumer.new(params['lti']['oauth_consumer_key'], params['oauth_consumer_secret'], {
      :site => "#{uri.scheme}://#{host}",
      :signature_method => "HMAC-SHA1"
  })

  path = uri.path
  path = '/' if path.empty?
  @lti_params = params['lti'].clone
  if uri.query != nil
    CGI.parse(uri.query).each do |query_key, query_values|
      unless @lti_params[query_key]
        @lti_params[query_key] = query_values.first
      end
    end
  end

  options = {
      :scheme           => 'body',
      :timestamp        => params['lti']['oauth_timestamp'],
      :nonce            => params['lti']['oauth_nonce'],
  }

  path = uri.path
  path = '/' if path.empty?

  signed_request = consumer.create_signed_request(:post, path, nil, options, @lti_params)

  signed_request_params = {}
  signed_request.body.split(/&/).each do |param|
    key, val = param.split(/=/).map{|v| CGI.unescape(v) }
    signed_request_params[key] = val
  end

  signature = OAuth::Signature.build(signed_request, :consumer_secret => params['oauth_consumer_secret'])
  @signature_base_string = consumer.signature_base_string(signed_request)
  @secret = signature.send(:secret)
  @oauth_signature = signed_request_params['oauth_signature']

  #
  #
  #require 'pry'
  #binding.pry
  #
  #oauth_consumer_secret = request.env['rack.request.form_hash'].delete('oauth_consumer_secret')
  #lti_request = Net::HTTP::Post.new(params['launch_url'])
  #signature = OAuth::Signature.build(request, :consumer_secret => oauth_consumer_secret)
  #@signature_base_string = signature.signature_base_string
  #@secret = signature.send(:secret)
  #@oauth_signature = signature.signature
  erb :proxy_launch
end

# post the assessment results
post '/assessment' do
  if session['launch_params']
    key = session['launch_params']['oauth_consumer_key']
  else
    show_error "The tool never launched"
    return erb :error
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], session['launch_params'])

  if !@tp.outcome_service?
    show_error "This tool wasn't lunched as an outcome service"
    return erb :error
  end

  # post the given score to the TC
  res = @tp.post_replace_result!(params['score'])

  if res.success?
    @score = params['score']
    @tp.lti_msg = "Message shown when arriving back at Tool Consumer."
    erb :assessment_finished
  else
    @tp.lti_errormsg = "The Tool Consumer failed to add the score."
    show_error "Your score was not recorded: #{res.description}"
    return erb :error
  end
end

get '/tool_config.xml' do
  host = request.scheme + "://" + request.host_with_port
  url = (params['signature_proxy_test'] ? host + "/signature_test" : host + "/lti_tool")
  tc = IMS::LTI::ToolConfig.new(:title => "Example Sinatra Tool Provider", :launch_url => url)
  tc.description = "This example LTI Tool Provider supports LIS Outcome pass-back."

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end

def was_nonce_used_in_last_x_minutes?(nonce, minutes=60)
  # some kind of caching solution or something to keep a short-term memory of used nonces
  false
end
