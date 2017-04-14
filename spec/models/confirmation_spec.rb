require 'rails_helper'

RSpec.describe Confirmation, type: :model do
  describe 'validations' do
    let(:confirmation) { Confirmation.new.tap(&:valid?) }
    specify { expect(confirmation.errors[:skill_id]).to eq(["can't be blank"])  }
    specify { expect(confirmation.errors[:user_id]).to eq(["can't be blank"])  }
    specify { expect(confirmation.errors[:claimant_id]).to eq(["can't be blank", "can't self confirm"])  }
    specify { expect(confirmation.errors[:rating]).to eq(["can't be blank"])  }
    specify { expect(confirmation.errors[:ipfs_reputon_key]).to eq(["can't be blank"])  }
  end

  describe 'no self confirmation' do
    let(:confirmation) { Confirmation.new(user_id: 1, claimant_id: 1).tap(&:valid?) }

    specify { expect(confirmation).to_not be_valid }
    specify { expect(confirmation.errors[:claimant_id]).to eq(["can't self confirm"])}
  end
end