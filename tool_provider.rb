require 'sinatra'
require 'ims/lti'
# must include the oauth proxy object
require 'oauth/request_proxy/rack_request'
require 'uuid'
require 'json'

enable :sessions
set :protection, :except => :frame_options
set :public_folder, File.dirname(__FILE__) + '/public'

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
    signature = OAuth::Signature.build(request, :consumer_secret => ($oauth_creds[key] || "secret"))

    @signature_base_string = signature.signature_base_string
    @secret = signature.send(:secret)

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

  @username = @tp.username("Dude")

  return true
end

# The url for launching the tool
# It will verify the OAuth signature
post '/lti_tool' do
  return show_error unless authorize!

  if @tp.get_custom_param('sub_canvas_xapi_url')
    @xapi_url = "/xapi?key=#{params['oauth_consumer_key']}&user_id=#{@tp.user_id}&xapi_url=#{@tp.get_custom_param('sub_canvas_xapi_url')}"
  end

  if @tp.get_custom_param('sub_canvas_caliper_url')
    @caliper_url = "/caliper?key=#{params['oauth_consumer_key']}&user_id=#{@tp.user_id}&caliper_url=#{@tp.get_custom_param('sub_canvas_caliper_url')}"
  end

  if @tp.outcome_service?
    # It's a launch for grading
    erb :assessment
  else
    # normal tool launch without grade write-back
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

  path = uri.path
  path = '/' if path.empty?

  proxied_request = consumer.send(:create_http_request, :post, path, @lti_params)
  signature = OAuth::Signature.build(proxied_request, :uri => params['launch_url'], :consumer_secret => params['oauth_consumer_secret'])

  @signature_base_string = signature.signature_base_string
  @secret = signature.send(:secret)
  @oauth_signature = signature.signature

  erb :proxy_launch
end

# post the assessment results
post '/assessment' do
  launch_params = request['launch_params']
  if launch_params
    key = launch_params['oauth_consumer_key']
  else
    show_error "The tool never launched"
    return erb :error
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], launch_params)
  @tp.extend IMS::LTI::Extensions::OutcomeData::ToolProvider

  if !@tp.outcome_service?
    show_error "This tool wasn't lunched as an outcome service"
    return erb :error
  end

  data = {}
  data['score'] = params['score'] if params['score'] && params['score'] != ''
  data['total_score'] = params['total_score'] if params['total_score'] && params['total_score'] != ''
  data['url'] = params['url'] if params['url'] && params['url'] != ''
  data['text'] = params['text'] if params['text'] && params['text'] != ''

  res = @tp.post_extended_replace_result!(data)

  if res.success?
    @score = params['score']
    @tp.lti_msg = "Message shown when arriving back at Tool Consumer."
    erb :assessment_finished
  else
    @tp.lti_errormsg = "The Tool Consumer failed to add the score."
    return show_error "Your score was not recorded: #{res.description}"
  end
end

get '/xapi' do
  key = params['key']
  xapi_url = params['xapi_url']
  user_id = params['user_id']

  unless key && xapi_url
    return show_error("The need key and callback url")
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], {})
  @tp.extend IMS::LTI::Extensions::OutcomeData::ToolProvider


  # generate the json body
  @body = {
          id: UUID.new,
          actor: {
                  account: {
                          homePage: context_url,
                          name: user_id
                  }
          },
          verb: {
                  id: "http://adlnet.gov/expapi/verbs/interacted",
                  display: {
                          "en-US" => "interacted"
                  }
          },
          object: {
                  id: context_url
          },
          result: {
                  duration: "PT5M30S"
          }
  }

  res = @tp.post_service_request(
          xapi_url,
          'application/json',
          @body.to_json)

  if res.code == '200'
    @tp.lti_msg = "Message shown when arriving back at Tool Consumer."
    erb :xapi_finished
  else
    @tp.lti_errormsg = "The Tool Consumer failed to add the activity."
    return show_error "Your activity was not recorded: #{res.description}"
  end

end

get '/caliper' do
  key = params['key']
  caliper_url = params['caliper_url']
  user_id = params['user_id']

  unless key && caliper_url
    return show_error("The need key and callback url")
  end

  @tp = IMS::LTI::ToolProvider.new(key, $oauth_creds[key], {})
  @tp.extend IMS::LTI::Extensions::OutcomeData::ToolProvider


  # generate the json body
  @body = {
          "@context" => "http://purl.imsglobal.org/ctx/caliper/v1/ViewEvent",
          "@type" => "http://purl.imsglobal.org/caliper/v1/ViewEvent",
          "action" => "viewed",
          "startedAtTime" => Time.now.utc.to_i,
          "duration" => "PT5M30S",
          "actor" => {
                  "@id" => user_id,
                  "@type" => "http://purl.imsglobal.org/caliper/v1/lis/Person"
          },
          "object" => {
                  "@id" => context_url,
                  "@type" => "http://www.idpf.org/epub/vocab/structure/#volume",
                  "name" => "Test LTI Tool"
          },
          "edApp" => {
                  "@id" => context_url,
                  "@type" => "http://purl.imsglobal.org/caliper/v1/SoftwareApplication",
                  "name" => "LTI Tool of All Things",
                  "properties" => {},
                  "lastModifiedTime" => Time.now.utc.to_i
          }
  }

  res = @tp.post_service_request(
          caliper_url,
          'application/json',
          @body.to_json)

  if res.code == '200'
    @tp.lti_msg = "Message shown when arriving back at Tool Consumer."
    erb :caliper_finished
  else
    @tp.lti_errormsg = "The Tool Consumer failed to add the activity."
    return show_error "Your activity was not recorded: #{res.description}"
  end

end

post '/content' do
  return show_error unless authorize!

  @tp.extend IMS::LTI::Extensions::Content::ToolProvider

  @context_url = context_url

  erb :content
end

def context_url
  url_scheme = request.ssl? ? "https" : "http"
  domain = request.env['SERVER_NAME']
  "#{url_scheme}://#{request.env['HTTP_HOST']}"
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
  content_ext_params = {:url => host + "/content"}
  text = "Content Extension Tool"

  if params['signature_proxy_test']
    url = host + "/signature_test"
    content_ext_params[:url] = url
    text = "LTI Signature Verifier"
  end

  navigation_params = {:url => url}

  tc = IMS::LTI::ToolConfig.new(:title => "Test Tool Provider", :launch_url => url)
  tc.description = "This example LTI Tool Provider supports LIS Outcome pass-back and the content extension."
  tc.extend IMS::LTI::Extensions::Canvas::ToolConfig

  tc.set_custom_param('sub_canvas_api_domain', '$Canvas.api.domain')
  tc.set_custom_param('sub_canvas_xapi_url', '$Canvas.xapi.url')
  tc.set_custom_param('sub_canvas_caliper_url', '$Canvas.caliper.url')
  tc.set_custom_param('sub_canvas_account_id', '$Canvas.account.id')
  tc.set_custom_param('sub_canvas_account_name', '$Canvas.account.name')
  tc.set_custom_param('sub_canvas_account_sis_sourceId', '$Canvas.account.sisSourceId')
  tc.set_custom_param('sub_canvas_root_account.id', '$Canvas.root_account.id')
  tc.set_custom_param('sub_canvas_root_account_sis_source_id', '$Canvas.root_account.sisSourceId')
  tc.set_custom_param('sub_canvas_course_id', '$Canvas.course.id')
  tc.set_custom_param('sub_canvas_course_sis_source_id', '$Canvas.course.sisSourceId')
  tc.set_custom_param('sub_canvas_enrollment_enrollment_state', '$Canvas.enrollment.enrollmentState')
  tc.set_custom_param('sub_canvas_membership_roles', '$Canvas.membership.roles')
  tc.set_custom_param('sub_canvas_membership_concluded_roles', '$Canvas.membership.concludedRoles')
  tc.set_custom_param('sub_canvas_user_id', '$Canvas.user.id')
  tc.set_custom_param('sub_canvas_user_sis_source_id', '$Canvas.user.sisSourceId')
  tc.set_custom_param('sub_canvas_user_login_id', '$Canvas.user.loginId')
  tc.set_custom_param('sub_person_name_full', '$Person.name.full')
  tc.set_custom_param('sub_person_name_family', '$Person.name.family')
  tc.set_custom_param('sub_person_name_given', '$Person.name.given')
  tc.set_custom_param('sub_person_email_primary', '$Person.email.primary')
  tc.set_custom_param('sub_person_address_timezone', '$Person.address.timezone')
  tc.set_custom_param('sub_user_image', '$User.image')

  tc.set_custom_param('sub_canvas_assignment_id', '$Canvas.assignment.id')
  tc.set_custom_param('sub_canvas_assignment_title','$Canvas.assignment.title')
  tc.set_custom_param('sub_canvas_assignment_points_possible', '$Canvas.assignment.pointsPossible')

  tc.canvas_privacy_public!
  tc.canvas_domain! request.host_with_port
  tc.canvas_text! text
  tc.canvas_icon_url! "#{host}/selector.png"
  tc.canvas_selector_dimensions! 500, 500
  tc.canvas_homework_submission! content_ext_params
  tc.canvas_editor_button! content_ext_params
  tc.canvas_resource_selection! content_ext_params
  tc.canvas_account_navigation! navigation_params
  tc.canvas_course_navigation! navigation_params
  tc.canvas_user_navigation! navigation_params

  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :migration_selection, content_ext_params)
  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :global_navigation, navigation_params)
  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :course_home_sub_navigation, navigation_params)

  content_response_params = navigation_params.merge(message_type: 'ContentItemSelectionResponse')
  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :quiz_menu, content_response_params)
  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :module_menu, content_response_params)
  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :assignment_menu, content_response_params)
  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :discussion_menu, content_response_params)
  tc.set_ext_param(IMS::LTI::Extensions::Canvas::ToolConfig::PLATFORM, :course_settings_sub_navigation, content_response_params)

  headers 'Content-Type' => 'text/xml'
  tc.to_xml(:indent => 2)
end

def was_nonce_used_in_last_x_minutes?(nonce, minutes=60)
  # some kind of caching solution or something to keep a short-term memory of used nonces
  false
end
