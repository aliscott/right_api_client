require 'rest_client' # rest_client 1.6.1
require 'json'
require 'set'
require 'cgi'

# RightApiClient has the generic get/post/delete/put calls that are used
# by resources
class RightApiClient

  ROOT_RESOURCE = '/api/session'
  ROOT_INSTANCE_RESOURCE = '/api/session/instance'

  # permitted parameters for initializing
  AUTH_PARAMS = %w(email password account_id api_url api_version cookies instance_token)
  
  INSTANCE_ACTIONS = {
    :clouds => {:volumes => 'do_get', :volume_types => 'do_get', :volume_attachments => 'do_get', :volume_snapshots => 'do_get', :instances => 'new_dummy'}
  }
  
  #
  # Methods shared by the RightApiClient, Resource and resource arrays.
  #
  module Helper

    # Helper used to add methods to classes
    def define_instance_method(meth, &blk)
      (class << self; self; end).module_eval do
        define_method(meth, &blk)
      end
    end

    # Helper method that returns all api methods available to a client
    # or resource
    def api_methods
      self.methods(false)
    end
    
    # Define methods that query the API for the associated resources
    # Some resources have many links with the same rel.
    # We want to capture all these href in the same method, returning an array
    def get_associated_resources(client, links, associations)
      # First go through the links and group the rels together
      rels = {}
      links.each do |link|
        if rels[link['rel'].to_sym]  # if we have already seen this rel attribute
          rels[link['rel'].to_sym] << link['href']
        else
          rels[link['rel'].to_sym] = [link['href']]
        end
      end
      
      # Note: hrefs will be an array, even if there is only one link with that rel
      rels.each do |rel,hrefs|
        # Add the link to the associations set if present. This is to accommodate Resource objects
        associations << rel if associations != nil
        
        # Create methods so that the link can be followed
        define_instance_method(rel) do |*args|
          if hrefs.size == 1 # Only one link for the specific rel attribute
            Resource.process(client, *client.do_get(hrefs.first, *args))
          else
            resources = []
            hrefs.each do |href|
              resources << Resource.process(client, *client.do_get(href, *args))
            end
            # return the array of resource objects
            resources
          end
        end if rels != :tags || rels != :backups
        
        # Design choice for tags since you cannot querry do_get on /api/tags:
        #  Instead of having tags_by_tag, tags_by_resource, tags_multi_add, and tags_multi_delete as root resources
        #  we allow tags to be a root resource, creating dummy object that has these methods with their corresponding actions
        define_instance_method(rel) do |*params|
          # hrefs will only have one element namely api/tags
          DummyResource.new(client, hrefs.first, {:by_tag => 'do_post', :by_resource => 'do_post', :multi_add => 'do_post', :multi_delete =>'do_post'})
        end if rel == :tags
        
        # The backups hack
        add_in_backups(client, hrefs.first) if rel == :backups
      end
    end
    
    # Specific to backups. A hack :<(
    # This extra hack is needed because:
    #   We want to call client.backups.create(params)  but client.backups does a GET and therefore needs the lineage as a parameter
    # Index, show, update, destroy and restore all need to take in parameters when you call backup so args will not be empty.
    
    def add_in_backups(client, path)
      define_instance_method(:backups) do |*args|
        if args != []
          Resource.process(client, *client.do_get(path, *args))
        else
          DummyResource.new(client, path, {:create => 'do_post', :cleanup => 'do_post'})
        end
      end
    end 
    #private :add_in_backups
    def add_id_to_path(path, params = {})
      path += "/#{params.delete(:id)}" if params.has_key?(:id)
      path
    end
  end
  

  include Helper

  # The cookies for our client.
  attr_reader :cookies

  def initialize(args)

    # Default params
    @api_url, @api_version = 'https://my.rightscale.com', '1.5'

    # Initializing all instance variables from hash
    args.each { |key,value|
      instance_variable_set("@#{key}", value) if value && AUTH_PARAMS.include?(key.to_s)
    } if args.is_a? Hash

    raise 'This API Client is only compatible with RightScale API 1.5 and upwards.' if (Float(@api_version) < 1.5)
    @client = RestClient::Resource.new(@api_url)

    # There are three options for login: credentials, instance token, or if the user already has the cookies they can just use those
    @cookies ||= login()

    if @instance_token
      define_instance_method(:get_instance) do |*params|
        Resource.process(self, *self.do_get(ROOT_INSTANCE_RESOURCE, *params))
      end
      # Like tags, you cannot call api/clouds when using an instance_token
      INSTANCE_ACTIONS.each do |dummy_meth, meths|
        define_instance_method(dummy_meth) do |*params|
          path = add_id_to_path("/api/clouds", *params)
          DummyResource.new(self, path, meths)
        end
      end
      # add in the hack for the backups
      add_in_backups(self, "/api/backups")
    else  
      # Session is the root resource that has links to all the base resources,
      # to the client since they can be accessed directly
      define_instance_method(:session) do |*params|
        Resource.process(self, *self.do_get(ROOT_RESOURCE, *params))
      end
      get_associated_resources(self, session.links, nil)
    end
  end
  
  
  
  def to_s
    "#<RightApiClient>"
  end
    
  # Log HTTP calls to file (file can be STDOUT as well)
  def log(file)
    RestClient.log = file
  end

  # Users shouldn't need to call the following methods directly

  # you can login with username and password or with an instance_token
  def login
    if @instance_token
      params = {
        'instance_token' => @instance_token
      }
      path = ROOT_INSTANCE_RESOURCE
    else
      params = {
        'email'        => @email,
        'password'     => @password,
      }
      path = ROOT_RESOURCE
    end
    params['account_href'] = "/api/accounts/#{@account_id}"

    response = @client[path].post(params, 'X_API_VERSION' => @api_version) do |response, request, result, &block|
      case response.code
      when 302
        response
      else
        response.return!(request, result, &block)
      end
    end
    response.cookies
  end

  def headers
    {'X_API_VERSION' => @api_version, :cookies => @cookies, :accept => :json}
  end

  # Generic get
  def do_get(path, params={})
    # Resource id is a special param as it needs to be added to the path
    path = add_id_to_path(path, params)

    # Normally you would just pass a hash of query params to RestClient,
    # but unfortunately it only takes them as a hash, and for filtering
    # we need to pass multiple parameters with the same key. The result
    # is that we have to build up the query string manually.
    filters = params.delete(:filters)
    params_string = params.map{|k,v| "#{k.to_s}=#{CGI::escape(v.to_s)}" }.join('&')

    if filters && filters.any?
      path += "?filter[]=" + filters.map{|f| CGI::escape(f) }.join('&filter[]=')
      path += "&#{params_string}"
    else
      path += "?#{params_string}"
    end

    # If present, remove ? and & at end of path
    path.chomp!('&')
    path.chomp!('?')

    begin
      # Return content type so the resulting resource object knows what kind of resource it is.
      resource_type, body = @client[path].get(headers) do |response, request, result, &block|
        case response.code
        when 200
          # Get the resource_type from the content_type, the resource_type will
          # be used later to add relevant methods to relevant resources.
          type = ''
          if result.content_type.index('rightscale')
            type = get_resource_type(result.content_type)
          end

          [type, response.body]
        else
          raise "Unexpected response #{response.code.to_s}, #{response.body}"
        end
      end
      #Session cookie is expired or invalid
    rescue RuntimeError => e
      if re_login?(e)
        @cookies = login()
        retry
      else
        raise e
      end
    end

    data = JSON.parse(body)

    [data, resource_type, path]
  end
  
  # Generic post
  def do_post(path, params={})
    begin
      @client[path].post(params, headers) do |response, request, result, &block|
        case response.code
        when 201, 202
          # Create and return the resource
          href = response.headers[:location]
          Resource.process(self, *self.do_get(href))
        when 200..299
          # this is needed for the tags Resource -- which returns a 200 and has a content type
          # therefore, a resource object needs to be returned
          if response.code == 200 && response.headers[:content_type].index('rightscale')
            type = get_resource_type(response.headers[:content_type])
            Resource.process(self, JSON.parse(response), type, path)
          else          
            response.return!(request, result, &block)
          end
        else
          raise "Unexpected response #{response.code.to_s}, #{response.body}"
        end
      end
    rescue RuntimeError => e
      if re_login?(e)
        @cookies = login()
        retry
      else
        raise e
      end
    end
  end

  # Generic delete
  def do_delete(path)
    begin
      @client[path].delete(headers) do |response, request, result, &block|
        case response.code
        when 200
        else
          raise "Unexpected response #{response.code.to_s}, #{response.body}"
        end
      end
    rescue RuntimeError => e
      if re_login?(e)
        @cookies = login()
        retry
      else
        raise e
      end
    end
  end

  # Generic put
  def do_put(path, params={})
    begin
      @client[path].put(params, headers) do |response, request, result, &block|
        case response.code
        when 204
        else
          raise "Unexpected response #{response.code.to_s}, #{response.body}"
        end
      end
    rescue RuntimeError => e
      if re_login?(e)
        @cookies = login()
        retry
      else
        raise e
      end
    end
  end

  def re_login?(e)
    e.message.index('403')
    # This will be added when the API distinguishes a session expired with this message
    # Note; delete the spec that checks if the cookie is corrupted when you add this line 
    #&& e.message =~ %r(.*Session cookie is expired or invalid) 
  end
  
  # returns the resource_type
  def get_resource_type(content_type)
    content_type.scan(/\.rightscale\.(.*)\+json/)[0][0]
  end

  # Given a path returns a RightApiClient::Resource instance.
  #
  def resource(path,params={})
    Resource.process(self, *do_get(path,params))
  end

  # This is need for resources like tags where the api/tags/ call is not supported.
  # This will define a dummy object and its methods
  class DummyResource
    include Helper
    # path is the base_resource's href
    # params is a hash where:
    #  key = method name
    #  value = action that is needed (like do_post, do_get...)
    def initialize(client, path, params={})
      params.each do |meth, action|
        define_instance_method(meth) do |*args|
          # do_get does not return a resource object (unlike do_post)
          if meth == :instances
            path = path.to_str + add_id_to_path("/instances", *args)
            DummyResource.new(client, path, {:live_tasks => 'do_get'})
          elsif meth == :live_tasks
            Resource.process(client, *client.do_get(path.to_str + '/live/tasks', *args))
          elsif action == 'do_get'
            Resource.process(client, *client.do_get(path.to_str + '/' + meth.to_s, *args))
          elsif meth == :create
            client.send action, path, *args
          else
            # send converts action (a string) into a method call
            client.send action, (path.to_str + '/' + meth.to_s), *args
          end
        end
      end
    end
  end
  
  # Represents resources returned by API calls, this class dynamically adds
  # methods and properties to instances depending on what type of resource
  # they are.
  class Resource
    include Helper

    # The API does not provide information about the basic actions that can be
    # performed on resources so we need to define them
    RESOURCE_ACTIONS = {
      :create => ['deployment', 'server_array', 'server', 'ssh_key', 'volume', 'volume_snapshot', 'volume_attachment'],
      :destroy => ['deployment', 'server_array', 'server', 'ssh_key', 'volume', 'volume_snapshot', 'volume_attachment', 'backup'],
      :update => ['deployment', 'instance', 'server_array', 'server', 'backup']
    }

    attr_reader :client, :attributes, :associations, :actions, :raw, :resource_type

    # Insert the given term at the correct place in the path, so
    # if there are parameters in the path then insert it before them.
    def self.insert_in_path(path, term)
      if path.index('?')
        new_path = path.sub('?', "/#{term}?")
      else
        new_path = "#{path}/#{term}"
      end
    end

    # Takes some response data from the API
    # Returns a single Resource object or a collection if there were many
    def self.process(client, data, resource_type, path)
      if data.kind_of?(Array)
        resource_array = data.map { |obj| Resource.new(client, obj, resource_type) }
        # Bring in the helper so we can add methods to it before it's returned.
        # The next few if statements might be nicer as a case but some
        # resources might need multiple methods so we'll keep things as
        # separate if statements for now.
        resource_array.extend(Helper)

        # Add create methods for the relevant resources
        if RESOURCE_ACTIONS[:create].include?(resource_type)
          resource_array.define_instance_method('create') do |*args|
            client.do_post(path, *args)
          end
        end

        # Add multi methods for the instance resource
        if ['instance'].include?(resource_type)
          ['multi_terminate', 'multi_run_executable'].each do |multi_action|
            multi_action_path = Resource.insert_in_path(path, multi_action)

            resource_array.define_instance_method(multi_action) do |*args|
              client.do_post(multi_action_path, *args)
            end
          end
        end

        # Add multi_update to input resource
        if ['input'].include?(resource_type)
          resource_array.define_instance_method('multi_update') do |*args|
            multi_update_path = Resource.insert_in_path(path, 'multi_update')

            client.do_put(multi_update_path, *args)
          end
        end

        resource_array
      else
        Resource.new(client, data, resource_type)
      end
    end

    def inspect
      "#<#{self.class.name} " +
      "resource_type=\"#{@resource_type}\"" +
      "#{', name='+name.inspect if self.respond_to?(:name)}" +
      "#{', resource_uid='+resource_uid.inspect if self.respond_to?(:resource_uid)}>"
    end

    def initialize(client, hash, resource_type)
      @client = client
      @resource_type = resource_type
      @raw = hash.dup
      @attributes, @associations, @actions = Set.new, Set.new, Set.new
      links = hash.delete('links') || []

      raw_actions = hash.delete('actions') || []

      # We obviously can't re-define a method called 'self', so pull
      # out the 'self' link and make it 'href'.
      self_index = links.any? && links.each_with_index do |link, idx|
        if link['rel'] == 'self'
          break idx
        end

        if idx == links.size-1
          break nil
        end
      end

      if self_index
        hash['href'] = links.delete_at(self_index)['href']
      end

      # Add links to attributes set and create a method that returns the links
      attributes << :links
      define_instance_method(:links) { return links }

      # API doesn't tell us whether a resource action is a GET or a POST, but
      # I think they are all post so add them all as posts for now.
      raw_actions.each do |action|
        action_name = action['rel']
        # Add it to the actions set
        actions << action_name.to_sym

        define_instance_method(action_name.to_sym) do |*args|
          href = hash['href'] + "/" + action['rel']
          client.do_post(href, *args)
        end
      end
      get_associated_resources(client, links, associations)
      
      hash.each do |k, v|
        # If a parent resource is requested with a view then it might return
        # extra data that can be used to build child resources here, without
        # doing another get request.
        if associations.include?(k.to_sym)
          # We could use one rescue block rather than these multiple ifs, but
          # exceptions are slow and the whole points of this code block is
          # optimization so we'll stick to using ifs.

          # v might be an array or hash so use include rather than has_key
          if v.include?('links')
            child_self_link = v['links'].find { |target| target['rel'] == 'self' }
            if child_self_link
              child_href = child_self_link['href']
              if child_href
                # Currently, only instances need this optimization, but in the
                # future we might like to extract resource_type from child_href
                # and not hard-code it.
                if child_href.index('instance')
                  define_instance_method(k) { Resource.process(client, v, 'instance', child_href) }
                end
              end
            end
          end
        else
          # Add it to the attributes set and create a method for it
          attributes << k.to_sym
          define_instance_method(k) { return v }
        end
      end

      # Some resources are not linked together, so they have to be manually
      # added here.
      case @resource_type
      when 'instance'
        define_instance_method('live_tasks') do |*args|
          Resource.process(client, *client.do_get(href + '/live/tasks', *args))
        end
      end

      # Add destroy method to relevant resources
      if RESOURCE_ACTIONS[:destroy].include?(@resource_type)
        define_instance_method('destroy') do
          client.do_delete(href)
        end
      end

      # Add update method to relevant resources
      if RESOURCE_ACTIONS[:update].include?(@resource_type)
        define_instance_method('update') do |*args|
          client.do_put(href, *args)
        end
      end
    end
  end
end

