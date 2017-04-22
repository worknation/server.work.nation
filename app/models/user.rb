class User < ApplicationRecord
  has_many :skills, foreign_key: :skill_claimant_id
  has_many :confirmations, foreign_key: :confirmer_id

  validates :uport_address, presence: true, uniqueness: true, format: { with: /\A0x[0-9a-fA-F]{40}\z/ }

  def to_param
    uport_address
  end

  def as_json(_options = {})
    {
      name: name,
      uportAddress: uport_address,
      avatar_image_ipfs_key: avatar_image_ipfs_key,
      banner_image_ipfs_key: banner_image_ipfs_key,
      skills: skills.map(&:as_json),
    }
  end

  def update_from_uport_profile!
    profile = Decentral::Uport.legacy_profile(uport_address)
    user = User.find_or_create_by!(uport_address: uport_address)
    user.update!(
      name: profile['name'],
      avatar_image_ipfs_key: profile['image'].try(:[], 'contentUrl')&.sub('/ipfs/', ''),
      banner_image_ipfs_key: profile['banner'].try(:[], 'contentUrl')&.sub('/ipfs/', ''),
    )
  end
end
