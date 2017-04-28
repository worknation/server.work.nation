require_relative 'log'

module Decentral
  class Claim
    extend Decentral::Log

    CLAIM_CONTRACT_ADDRESS = '0x0ac188eb03917623292784dfc01e5e330e684fc4'.freeze
    CLAIM_CONTRACT_ABI = JSON.parse %( [{"constant":false,"inputs":[{"name":"claim","type":"string"}],"name":"getSigner","outputs":[{"name":"_signer","type":"address"}],"payable":false,"type":"function"},{"constant":false,"inputs":[{"name":"_claim","type":"string"}],"name":"put","outputs":[{"name":"_success","type":"bool"}],"payable":false,"type":"function"},{"constant":false,"inputs":[{"name":"index","type":"uint256"}],"name":"getClaim","outputs":[{"name":"_claim","type":"string"}],"payable":false,"type":"function"},{"constant":false,"inputs":[{"name":"_claim1","type":"string"},{"name":"_claim2","type":"string"}],"name":"put2","outputs":[{"name":"_success","type":"bool"}],"payable":false,"type":"function"},{"constant":true,"inputs":[],"name":"claimCount","outputs":[{"name":"","type":"uint256"}],"payable":false,"type":"function"},{"constant":true,"inputs":[{"name":"","type":"uint256"}],"name":"claims","outputs":[{"name":"","type":"string"}],"payable":false,"type":"function"},{"constant":false,"inputs":[],"name":"whoami","outputs":[{"name":"","type":"address"}],"payable":false,"type":"function"},{"payable":false,"type":"fallback"}] )
    REDIS = if ENV['REDISTOGO_URL']
      Redis.new(url: URI.parse(ENV['REDISTOGO_URL']))
    else
      Redis.new
    end

    def self.reset_claim_count
      REDIS.set('known_claim_count', -1)
    end

    def self.get_latest_claims
      # pry.debugger
      client = Ethereum::HttpClient.new(ENV['ETHEREUM_RPC_URL'])

      contract = Ethereum::Contract.create(
        name: 'Claim',
        address: CLAIM_CONTRACT_ADDRESS,
        abi: CLAIM_CONTRACT_ABI,
        client: client,
      )

      claim_count = contract.call.claim_count
      known_claim_count = Integer(REDIS.get('known_claim_count') || -1)
      log_counts "Max known claim in Ethereum: #{claim_count - 1}"
      log_counts "Max known claim in local db: #{known_claim_count}"

      (known_claim_count + 1...claim_count).each do |claim_index|
        get_claim(claim_index, contract)
      end
    end

    def self.get_claim(claim_index, contract)
      log "\n"
      log_h1 "Claim ##{claim_index}"
      ipfs_key = contract.call.get_claim(claim_index)
      signer = contract.call.get_signer(ipfs_key)

      log ipfs_url = "https://ipfs.io/ipfs/#{ipfs_key}"
      response = HTTParty.get(ipfs_url)
      # puts response.body, response.code #, response.message, response.headers.inspect
      log response.code
      if response.code != 200
        raise Decentral::NotFound, "Error fetching #{ipfs_url} -- #{response.body} -- #{response.code}"
      end

      content = response.body
      parse(content, ipfs_key, ipfs_url, signer)
    rescue DecentralError => e
      Decentral.handle_error e
    ensure
      log_counts "SETTING known_claim_count: #{claim_index}"
      REDIS.set('known_claim_count', claim_index)
    end

    def self.parse(content, ipfs_key, ipfs_url, signer)
      begin
        data = JSON.parse(content)
      rescue JSON::ParserError
        raise Decentral::InvalidFormatError, "Expected JSON from #{ipfs_url}, but got: [[ #{content[0...1000]} ]]"
      end

      if data.keys.sort == %w[application reputons]
        save_reputon(data, signer, ipfs_key)
      elsif data['type'] == 'project'
        save_project(data)
      elsif data['type'] == 'permanode'
        log_info 'permanode:', data
      else
        raise Decentral::InvalidFormat, "Could not determine claim type; content: [[ #{content[0...1000]} ]]"
      end
    end

    def self.save_project(params)
      # TODO
      # - fetch permanode
      # - compare permanode creator to permanode signer, raise if not same
      # - compare permanode creator to project profile signer, raise if not same
      # - store creator on Project#permanode_creator_uport_address
      # - compare permanode creator to signer, raise if not same

      skill_list = params['skills']
      params.deep_transform_keys!(&:underscore)
      project = Project.new params.without('type', 'timestamp', 'skills')
      project.skill_list = skill_list
      project.save!
    rescue => e
      raise InvalidFormat, "Project saving failed from params: #{params.inspect} ( original params: #{orig_params.inspect} )
        \nFrom: #{e.inspect}"
      # {
      #     address: "",
      #     contact: "",
      #     imageUrl: "",
      #     permanodeId: "/ipfs/QmY6GV3ME9DYEtYYHTwnBB33VFXsLGF2K4JuJBam8eLXyf",
      #     skills: "",
      #     title: "",
      #     type: "project"
      # }
    end

    def self.save_reputon(reputons_envelope, signer, ipfs_key)
      log reputons_envelope
      application = reputons_envelope['application']
      if application != 'skills'
        raise ReputonInvalid, "Expected application 'skills' but was: #{reputons_envelope['application']}.\nReputons:\n#{JSON.pretty_unparse(reputons_envelope)}"
      end

      reputons_data = reputons_envelope['reputons']
      reputons_data.each do |reputon_data|
        begin
          reputon = Claim.new(reputon_data, signer, ipfs_key)
          reputon.save!
        rescue DecentralError => e
          Decentral.handle_error e
        end
      end
    end

    def initialize(data, signer, ipfs_key)
      @data = data
      @signer = signer
      @ipfs_key = ipfs_key
    end

    def save!
      if address(@data['rater']) != address(@signer)
        raise ReputonSignatureInvalid, "Reputon rater: #{@data['rater'].inspect} should match transaction signer: #{@signer.inspect}.\nFull reputon:\n#{JSON.pretty_unparse(@data)}"
      end
      if @data['rater'] == @data['rated']
        save_skill!
      else
        save_confirmation!
      end
    end

    def save_skill!
      user = User.find_or_create_by(uport_address: @data['rater'])
      skill_claim = user.skill_claims.find_by(ipfs_reputon_key: @ipfs_key)
      return if skill_claim.present?
      log user.skill_claims.create!(
        name: @data['assertion'],
        ipfs_reputon_key: @ipfs_key,
      )
    end

    def save_confirmation!
      # TODO: reject conf if normal rating not 0.5

      confirmer = User.find_or_create_by(uport_address: @data['rater'])
      skill_claim = SkillClaim.find_by(ipfs_reputon_key: @data['rated'])
      if skill_claim.blank?
        raise ReputonInvalid, "No skill_claim found for [#{@data['rated']}].\nFull reputon:\n#{JSON.pretty_unparse(@data)}"
      end
      if address(confirmer.uport_address) == address(skill_claim.user.uport_address)
        raise ReputonInvalid, "Attempting to self confirm, rejected.\nFull reputon:\n#{JSON.pretty_unparse(@data)}"
      end
      confirmation = Confirmation.find_by(ipfs_reputon_key: @ipfs_key)
      return if confirmation.present?
      log confirmer.confirmations.create!(
        user: confirmer,
        skill_claim: skill_claim,
        claimant: skill_claim.user,
        rating: @data['rating'],
        ipfs_reputon_key: @ipfs_key,
      )
    end

    def address(candidate)
      candidate&.sub(/^0x/, '')
    end
  end
end
