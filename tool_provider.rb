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

def register_error(message)
  @error_message = message
end

def show_error(message = nil)
  @message = message || @error_message || "An unexpected error occurred"
  erb :error
end

def authorize!
  if key = params['oauth_consumer_key']
    if secret = $oauth_creds[key]
      @tp = IMS::LTI::ToolProvider.new(key, secret, params)
    else
      @tp = IMS::LTI::ToolProvider.new(nil, nil, params)
      @tp.lti_msg = "Your consumer didn't use a recognized key."
      @tp.lti_errorlog = "You did it wrong!"
      register_error "Consumer key wasn't recognized"
      return false
    end
  else
    register_error "No consumer key"
    return false
  end

  if !@tp.valid_request?(request)
    register_error "The OAuth signature was invalid"
    return false
  end

  if Time.now.utc.to_i - @tp.request_oauth_timestamp.to_i > 60*60
    register_error "Your request is too old."
    return false
  end

  # this isn't actually checking anything like it should, just want people
  # implementing real tools to be aware they need to check the nonce
  if was_nonce_used_in_last_x_minutes?(@tp.request_oauth_nonce, 60)
    register_error "Why are you reusing the nonce?"
    return false
  end

  # save the launch parameters for use in later request
  session['launch_params'] = @tp.to_params

  @username = @tp.username("Dude")
end

# The url for launching the tool
# It will verify the OAuth signature
post '/lti_tool' do
  return show_error unless authorize!

  if @tp.outcome_service?
    # It's a launch for grading
    erb :assessment
  else
    # normal tool launch without grade write-back
    @tp.lti_msg = "Sorry that tool was so boring"
    erb :boring_tool
  end
end

# post the assessment results
post '/assessment' do
  if session['launch_params']
    key = session['launch_params']['oauth_consumer_key']
  else
    return show_error "The tool never launched"
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], session['launch_params'])

  if !@tp.outcome_service?
    return show_error "This tool wasn't lunched as an outcome service"
  end

  # post the given score to the TC
  res = @tp.post_replace_result!(params['score'])

  if res.success?
    @score = params['score']
    @tp.lti_msg = "Message shown when arriving back at Tool Consumer."
    erb :assessment_finished
  else
    @tp.lti_errormsg = "The Tool Consumer failed to add the score."
    return show_error "Your score was not recorded: #{res.description}"
  end
end

post '/content' do
  return show_error unless authorize!

  @tp.extend IMS::LTI::Extensions::Content::ToolProvider

  url_scheme = request.ssl? ? "https" : "http"
  domain = request.env['SERVER_NAME']
  @context_url = "#{url_scheme}://#{request.env['HTTP_HOST']}"

  erb :content
end

get '/public' do
  'This is a public page'
end

get '/oembed' do
  content_type :json
  require 'json'

  { "version" => "1.0",
    "type" => "video",
    "provider_name" => "YouTube",
    "provider_url" => "http://youtube.com/",
    "width" => 425,
    "height" => 344,
    "title" => "Amazing Nintendo Facts",
    "author_name" => "ZackScott",
    "author_url" => "http://www.youtube.com/user/ZackScott",
    "html" =>
    "<object width=\"425\" height=\"344\">
			<param name=\"movie\" value=\"http://www.youtube.com/v/M3r2XDceM6A&fs=1\"></param>
			<param name=\"allowFullScreen\" value=\"true\"></param>
			<param name=\"allowscriptaccess\" value=\"always\"></param>
			<embed src=\"http://www.youtube.com/v/M3r2XDceM6A&fs=1\"
				type=\"application/x-shockwave-flash\" width=\"425\" height=\"344\"
				allowscriptaccess=\"always\" allowfullscreen=\"true\"></embed>
		</object>" }.to_json
end

get '/tool_config.xml' do
  host = request.scheme + "://" + request.host_with_port
  url = host + "/lti_tool"

  tc = IMS::LTI::ToolConfig.new(:title => "Example Sinatra Tool Provider", :launch_url => url)
  tc.description = "This example LTI Tool Provider supports LIS Outcome pass-back and the content extension."
  tc.extend IMS::LTI::Extensions::Canvas::ToolConfig
  tc.canvas_privacy_public!
  tc.canvas_domain! request.host_with_port
  tc.canvas_text! "Content Extension Tool"
  tc.canvas_icon_url! "#{host}/selector.png"
  tc.canvas_selector_dimensions! 300, 500
  params = {:url => host + "/content"}
  tc.canvas_homework_submission! params
  tc.canvas_editor_button! params
  tc.canvas_resource_selection! params

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end

def was_nonce_used_in_last_x_minutes?(nonce, minutes=60)
  # some kind of caching solution or something to keep a short-term memory of used nonces
  false
end
