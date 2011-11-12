require 'base64'
require 'json'
require 'git'
require 'fileutils'
require 'net/sftp'

require File.expand_path(File.join(File.dirname(__FILE__), '/capistrano/h'))

module Railshoster
  
  # This action class helps to setup a new rails applicaton
  class InitCommand < Command        
    
    def initialize(project_dir)
      super(project_dir)
    end
        
    def run_by_application_token(application_token) 
      decoded_token = decode_token(application_token)
      
      begin
        run_by_application_hash(decoded_token)
      rescue BadApplicationJSONHashError => e
        msg = "Please verify your application_token. It did not decode to a valid application hash.\n" +
          "This is how your application token looked like:\n\n#{application_token.inspect}\n\n" +
          "Please compare your application token char by char with your account information mail and try again!\n" +
          "Here is what the application hash parser said:\n\n"
        raise BadApplicationTokenError.new(msg + e.message)
      end
    end
    
    def run_by_application_hash(application_hash_as_json_string)
      app_hash = parse_application_json_hash(application_hash_as_json_string)
      
      # Extract GIT URL from project and add it to the app_hash
      git_url = get_git_remote_url_from_git_config          
      app_hash["git"] = git_url

      #TODO Add connection test -> If there's already access -> no need to do this
      selected_key = Railshoster::Utilities.select_public_ssh_key  
      app_hash["public_ssh_key"] = Pathname.new(selected_key[:path]).basename.to_s.gsub(".pub", "")
      
      create_remote_authorized_key_file_from_public_ssh_key(app_hash, selected_key)
      deployrb_str = create_deployrb(app_hash)      
      write_deploy_rb(deployrb_str)
      capify_project
      success_message
    end
    
    protected
    
    def create_remote_authorized_key_file_from_public_ssh_key(app_hash, key)
      remote_dot_ssh_path = ".ssh"
      remote_authorized_keys_path = remote_dot_ssh_path + "/authorized_keys"
      Net::SFTP.start(app_hash["h"], app_hash["u"], :password => app_hash["p"]) do |sftp|                
        begin
          sftp.mkdir!(remote_dot_ssh_path)
        rescue Net::SFTP::StatusException => e
          # Most likely the .ssh folder already exists raise again if not.
          raise e unless e.code == 4
        end
        sftp.upload!(key[:path].to_s, remote_authorized_keys_path)
      end      
    end          
    
    def create_deployrb(app_hash)
      deployrb_str = ""
      
      # Choose the further process depending on the application type by applying a strategy pattern.
      case app_hash["t"].to_sym
        when :h
          # Shared Hosting Deployments
          deployrb_str = Railshoster::Capistrano::H.render_deploy_rb_to_s(app_hash)
        # Later also support VPS Deployments
        # when :v
        else
          raise UnsupportedApplicationTypeError.new
      end
    end    
    
    # Decodoes token to get the JSON hash back.
    # gQkUSMakKRPhm0EIaer => {"key":"value"}
    def decode_token(token)      
      Base64.decode64(token)
    end
    
    def parse_application_json_hash(app_hash_as_json_string)
      begin
        ruby_app_hash = ::JSON.parse(app_hash_as_json_string)      
      rescue JSON::ParserError => e      
        msg = "The application hash you have passed is malformed. It could not be parsed as regular JSON. It looked like this:\n\n #{app_hash_as_json_string.inspect}\n"  
        raise BadApplicationJSONHashError.new(msg + "\nHere is what the JSON parse said:\n\n" + e.message)
      end
    end
    
    def get_git_remote_url_from_git_config
      
      #TODO Error management: what if there is not remote url (local repo)?
      @git.config['remote.origin.url']
    end
    
    def write_deploy_rb(deployrb_str)
      deployrb_basepath = File.join(@project_dir, "config")
      FileUtils.mkdir_p(deployrb_basepath)
      
      deployrb_path = File.join(deployrb_basepath, "deploy.rb")
      Railshoster::Utilities.backup_file(deployrb_path) if File.exists?(deployrb_path)
      
      File.open(deployrb_path, "w+") { |f| f << deployrb_str }
    end      
    
    def capify_project      
      puts "\n\tWarning: You are initializing a project with an existing Capfile.\n" if capfile_exists?
      successful = system("capify #{@project_dir}")
      raise CapifyProjectFailedError.new("Couldn't capify project at #{@project_dir}") unless successful
    end
    
    def success_message
      puts "Your application has been successfully initialized."
      puts "\n\tYou can now use 'railshoster deploy' to deploy your app.\n\n"
      puts "Alternatively, you can use capistrano commands such as 'cap deploy' and 'cap shell'."
    end
  end
end