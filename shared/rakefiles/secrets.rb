require "base64"
require "json"
require "openssl"
require "securerandom"
require "yaml"

class Secrets

  KMS_KEYRING  = "keyring"
  KMS_LOCATION = "global"

  SECRETS_DIR  = "secrets"
  SECRETS_FILE = "secrets.yaml"

  GOOGLE_CLOUD_API = "https://www.googleapis.com"
  GOOGLE_KMS_API   = "https://cloudkms.googleapis.com"

  # This method is looking for SECRETS_FILE files in module directories (modules/*), which should have the following structure:
  #
  # secrets:
  #  - secret_module_admin_password
  #  - secret_module_another_secret
  #  - secret_module_and_one_more_secret
  # encryption_key: default
  #
  # Config file gcp/modules/gcp-secret-mgmt/config.yaml
  # is needed to preserve the order of encryption keys.
  # All used encryption keys must be present in that config, otherwise exception is raised
  # More info: https://issues.gpii.net/browse/GPII-3456
  #
  # Attribute "encryption_key" is optional – if not present, module name will be used as Key name
  # After collecting, method returns the Hash with collected secrets, where the keys are KMS Encryption Keys and the values are
  # lists of individual credentials (e.g. couchdb_password) managed with that KMS Encryption Key
  #
  # In case duplicated secrets found, exception is raised
  # All secrets must start with special prefix, otherwise exception is raised
  #
  # For prefix "secret_" random hexadecimal string(16) will be generated if ENV value not set
  # For prefix "key_" new OpenSSL aes-256-cfb key will be generated and packed in Base64 if ENV value not set
  #
  # We also advice to add module name to each secret's name (e.g. "secret_couchdb_admin_password" instead of just "secret_admin_password")
  # to avoid naming collisions, since secrets scope is global
  def self.collect_secrets()
    ENV['TF_VAR_keyring_name'] = Secrets::KMS_KEYRING

    collected_secrets = {}
    secrets_to_modules = {}

    Dir["./modules/**/#{Secrets::SECRETS_FILE}"].each do |module_secrets_file|
      module_name = File.basename(File.dirname(module_secrets_file))
      module_secrets = YAML.load(File.read(module_secrets_file))

      encryption_key = module_secrets['encryption_key'] ? module_secrets['encryption_key'] : module_name

      if collected_secrets[encryption_key]
        collected_secrets[encryption_key].concat(module_secrets['secrets'])
      else
        collected_secrets[encryption_key] = module_secrets['secrets']
      end
      module_secrets['secrets'].each do |secret_name|
        if !(secret_name.start_with?("secret_") || secret_name.start_with?("key_"))
          raise "ERROR: Can not use secret with name '#{secret_name}' for module '#{module_name}'!\n \
            Secret name must start with 'secret_' or 'key_'!"
        elsif secrets_to_modules.include? secret_name
          raise "ERROR: Can not use secret with name '#{secret_name}' for module '#{module_name}'!\n \
            Secret '#{secret_name}' is already in use by module '#{secrets_to_modules[secret_name]}'!"
        end
        ENV["TF_VAR_#{secret_name}"] = "" unless ENV["TF_VAR_#{secret_name}"]
        secrets_to_modules[secret_name] = module_name
      end
    end

    encryption_keys = {}
    secrets_config = YAML.load(File.read("./modules/gcp-secret-mgmt/config.yaml"))
    secrets_config["encryption_keys"].each do |encryption_key|
      encryption_keys[encryption_key] = %Q|"#{encryption_key}"|
    end

    leftover_keys = collected_secrets.keys - encryption_keys.keys
    unless leftover_keys.empty?
      puts "ERROR: Secret keys: \"#{leftover_keys.join(", ")}\" not present in"
      puts "ERROR: gcp/modules/gcp-secret-mgmt/config.yaml"
      raise
    end

    ENV["TF_VAR_encryption_keys"] = %Q|[ #{encryption_keys.values.join(", ")} ]|

    return collected_secrets
  end


  # This method is setting secret ENV variables collected from modules
  #
  # When encrypted secret file for current env is not present it GS bucket,
  # for every secret it first looks for ENV["TF_VAR_#{secret_name}"] and, if it is not set,
  # populates secret with random nonse, and then uploads to corresponding GS bucket.
  #
  # When encrypted secret file is present, it always uses its decrypted data as a source for secrets.
  # When `rotate_secrets` is set to true, secrets will be set from env vars, encrypted secret file will be
  # re-generated and re-uploaded into GS bucket.
  # Use `rake destroy_secrets[KEY_NAME]` to forcefully repopulate secrets for target encryption key.
  def self.set_secrets(collected_secrets, rotate_secrets = false)
    collected_secrets.each do |encryption_key, secrets|
      decrypted_secrets = fetch_secrets(encryption_key) unless secrets.empty? or rotate_secrets

      if decrypted_secrets
        decrypted_secrets.each do |secret_name, secret_value|
          ENV["TF_VAR_#{secret_name}"] = secret_value
        end
      else
        next if secrets.empty?
        puts "[secret-mgmt] Populating secrets for key '#{encryption_key}'..."
        populated_secrets = {}
        secrets.each do |secret_name|
          if ENV["TF_VAR_#{secret_name}"].to_s.empty?
            if secret_name.start_with?("key_")
              key = OpenSSL::Cipher::AES256.new.encrypt.random_key
              secret_value = Base64.strict_encode64(key)
            else
              secret_value = SecureRandom.hex
            end
            ENV["TF_VAR_#{secret_name}"] = secret_value
          else
            secret_value = ENV["TF_VAR_#{secret_name}"]
          end
          populated_secrets[secret_name] = secret_value
        end

        push_secrets(populated_secrets, encryption_key)
      end
    end

    # TODO: Next line should be removed once Terraform issue with GCS backend encryption is fixed
    # https://issues.gpii.net/browse/GPII-3329
    ENV['GOOGLE_ENCRYPTION_KEY'] = ENV['TF_VAR_key_tfstate_encryption_key']
  end

  def self.push_secrets(secrets, encryption_key)
    gs_bucket = "#{ENV['TF_VAR_project_id']}-#{encryption_key}-secrets"
    encoded_secrets = Base64.encode64(secrets.to_json).delete!("\n")

    puts "[secret-mgmt] Retrieving primary key version for key '#{encryption_key}'..."
    encryption_key_version = %x{
      curl -s \
      -H \"Authorization:Bearer $(gcloud auth print-access-token)\" \
      -H \"Content-Type:application/json\" \
      -X GET \"#{Secrets::GOOGLE_KMS_API}/v1/projects/#{ENV['TF_VAR_project_id']}/locations/#{Secrets::KMS_LOCATION}/keyRings/#{Secrets::KMS_KEYRING}/cryptoKeys/#{encryption_key}\"
    }

    begin
      encryption_key_version = JSON.parse(encryption_key_version)
      encryption_key_version = get_crypto_key_version(encryption_key_version['primary']['name'])
    rescue
      debug_output "ERROR: Unable to get primary encryption key version for key '#{encryption_key}', terminating!", encryption_key_version
      raise
    end

    puts "[secret-mgmt] Encrypting secrets with key '#{encryption_key}' version #{encryption_key_version}..."
    encrypted_secrets = %x{
      curl -s \
      -H \"Authorization:Bearer $(gcloud auth print-access-token)\" \
      -H \"Content-Type:application/json\" \
      -X POST \"#{Secrets::GOOGLE_KMS_API}/v1/projects/#{ENV['TF_VAR_project_id']}/locations/#{Secrets::KMS_LOCATION}/keyRings/#{Secrets::KMS_KEYRING}/cryptoKeys/#{encryption_key}/cryptoKeyVersions/#{encryption_key_version}:encrypt\" \
      -d \"{\\\"plaintext\\\":\\\"#{encoded_secrets}\\\"}\"
    }

    begin
      response_check = JSON.parse(encrypted_secrets)
    rescue
      debug_output "ERROR: Unable to parse encrypted secrets data for key '#{encryption_key}', terminating!"
      raise
    end

    puts "[secret-mgmt] Uploading encrypted secrets for key '#{encryption_key}' into GS bucket..."
    encrypted_secrets = Base64.encode64(encrypted_secrets).delete!("\n")
    api_call_data = %x{
      curl -s \
      -H \"Authorization:Bearer $(gcloud auth print-access-token)\" \
      -X POST \"#{Secrets::GOOGLE_CLOUD_API}/upload/storage/v1/b/#{gs_bucket}/o?uploadType=media&name=#{Secrets::SECRETS_FILE}\" \
      -d \"#{encrypted_secrets}\"
    }

    begin
      response_check = JSON.parse(api_call_data)
    rescue
      debug_output "ERROR: Unable to upload encrypted secrets for key '#{encryption_key}' into GS bucket, terminating!"
      raise
    end
  end

  def self.fetch_secrets(encryption_key)
    gs_bucket = "#{ENV['TF_VAR_project_id']}-#{encryption_key}-secrets"
    gs_secrets_file = "#{gs_bucket}/o/#{Secrets::SECRETS_FILE}"

    puts "[secret-mgmt] Checking if secrets file for key '#{encryption_key}' is present in GS bucket..."
    api_call_data = %x{
      curl -s \
      -H \"Authorization:Bearer $(gcloud auth print-access-token)\" \
      -X GET \"#{Secrets::GOOGLE_CLOUD_API}/storage/v1/b/#{gs_secrets_file}\"
    }

    begin
      gs_secrets = JSON.parse(api_call_data)
    rescue
      debug_output "ERROR: Unable to parse GS secrets file data for key '#{encryption_key}', terminating!"
      raise
    end

    if gs_secrets['error'] && gs_secrets['error']['code'] == 404
      puts "[secret-mgmt] Encrypted secrets for key '#{encryption_key}' is missing in GS bucket..."
      return
    end

    puts "[secret-mgmt] Retrieving encrypted secrets for key '#{encryption_key}' from GS bucket..."
    api_call_data = %x{
      curl -s \
      -H \"Authorization:Bearer $(gcloud auth print-access-token)\" \
      -X GET \"#{Secrets::GOOGLE_CLOUD_API}/storage/v1/b/#{gs_secrets_file}?alt=media\"
    }

    gs_secrets = JSON.parse(Base64.decode64(api_call_data))
    if !gs_secrets['ciphertext']
      debug_output "ERROR: Unable to extract ciphertext from YAML data for key '#{encryption_key}', terminating!"
      raise
    end

    puts "[secret-mgmt] Decrypting secrets for key '#{encryption_key}' with KMS key version #{get_crypto_key_version(gs_secrets['name'])}..."
    decrypted_secrets = %x{
      curl -s \
      -H \"Authorization:Bearer $(gcloud auth print-access-token)\" \
      -H \"Content-Type:application/json\" \
      -X POST \"#{Secrets::GOOGLE_KMS_API}/v1/projects/#{ENV['TF_VAR_project_id']}/locations/#{Secrets::KMS_LOCATION}/keyRings/#{Secrets::KMS_KEYRING}/cryptoKeys/#{encryption_key}:decrypt\" \
      -d \"{\\\"ciphertext\\\":\\\"#{gs_secrets['ciphertext']}\\\"}\"
    }

    begin
      decrypted_secrets = JSON.parse(decrypted_secrets)
      decrypted_secrets = JSON.parse(Base64.decode64(decrypted_secrets['plaintext']))
    rescue
      debug_output "ERROR: Unable to parse secrets data for key '#{encryption_key}', terminating!"
      raise
    end

    return decrypted_secrets
  end

  # This method creates new primary version for target encryption_key
  def self.create_key_version(encryption_key)
    puts "[secret-mgmt] Creating new primary version for key '#{encryption_key}'..."
    new_version = %x{
      gcloud kms keys versions create \
      --location #{Secrets::KMS_LOCATION} \
      --keyring #{Secrets::KMS_KEYRING} \
      --key #{encryption_key} \
      --primary --format json
    }

    begin
      new_version = JSON.parse(new_version)
      new_version_id = get_crypto_key_version(new_version["name"])
    rescue
      debug_output "ERROR: Unable to create new version for key '#{encryption_key}', terminating!", new_version
      raise
    end

    return new_version_id
  end

  # This method disables all versions except primary for target encryption_key
  def self.disable_non_primary_key_versions(encryption_key, primary_version_id)
    puts "[secret-mgmt] Retrieving versions for key '#{encryption_key}'..."
    key_versions = %x{
      gcloud kms keys versions list \
      --location #{Secrets::KMS_LOCATION} \
      --keyring #{Secrets::KMS_KEYRING} \
      --key #{encryption_key} \
      --format json
    }

    begin
      key_versions = JSON.parse(key_versions)
    rescue
      debug_output "ERROR: Unable to retrieve versions for key '#{encryption_key}', terminating!", key_versions
      raise
    end

    key_versions.each do |version|
      version_id = get_crypto_key_version(version["name"])
      next if version["state"] != "ENABLED" or version_id == primary_version_id

      puts "[secret-mgmt] Disabling version #{version_id} for key '#{encryption_key}'..."
      version_disabled = %x{
        gcloud kms keys versions disable #{version_id} \
        --location #{Secrets::KMS_LOCATION} \
        --keyring #{Secrets::KMS_KEYRING} \
        --key #{encryption_key} \
        --format json
      }

      begin
        version_disabled = JSON.parse(version_disabled)
        raise unless version_disabled['state'] == "DISABLED"
      rescue
        debug_output "ERROR: Unable to disable version #{version_id} for key '#{encryption_key}', terminating!", version_disabled
        raise
      end
    end
  end

  # This method returns KMS key version number from path:
  # PATH: `projects/gpii-gcp-dev-tyler/locations/global/keyRings/keyring/cryptoKeys/default/cryptoKeyVersions/1`
  def self.get_crypto_key_version(path)
    return path.match(/\/([0-9]+)$/)[1]
  end

  # This method outputs error message and api response
  def self.debug_output(message, api_response = '')
    puts
    puts message
    puts
    if api_response
      puts "Response from API was:"
      puts api_response
      puts
    end
  end
end

# vim: et ts=2 sw=2:
