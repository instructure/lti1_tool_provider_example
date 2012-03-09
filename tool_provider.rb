require 'sinatra'
require 'ims/lti'
# must include the oauth proxy object
require 'oauth/request_proxy/rack_request'

enable :sessions

get '/' do
  erb :index
end

# the consumer keys/secrets
$oauth_creds = {"test" => "secret", "testing" => "supersecret"}

def show_error(message)
  @message = message
  erb :error
end

# The url for launching the tool
# It will verify the OAuth signature
post '/lti_tool' do
  if key = params['oauth_consumer_key']
    if secret = $oauth_creds[key]
      @tp = IMS::LTI::ToolProvider.new(key, secret, params)
    else
      show_error "Consumer key wasn't recognized"
      return
    end
  else
    show_error "No consumer key"
    return
  end

  if !@tp.valid_request?(request)
    show_error "The OAuth signature was invalid"
    return
  end

  # save the launch parameters for use in later request
  session['launch_params'] = @tp.to_params

  @username = @tp.username("Dude")
  if @tp.outcome_service?
    # It's a launch for grading
    erb :assessment
  else
    # normal tool launch without grade write-back
    erb :boring_tool
  end
end

# post the assessment results
post '/assessment' do
  if session['launch_params']
    key = session['launch_params']['oauth_consumer_key']
  else
    show_error "The tool never launched"
    return
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], session['launch_params'])

  if !@tp.outcome_service?
    show_error "This tool wasn't lunched as an outcome service"
    return
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
  end
end

get '/tool_config.xml' do
  host = request.scheme + "://" + request.host_with_port
  url = host + "/lti_tool"
  tc = IMS::LTI::ToolConfig.new(:title => "Example Sinatra Tool Provider", :launch_url => url)
  tc.description = "This example LTI Tool Provider supports LIS Outcome pass-back."

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end
