require 'rails_helper'

RSpec.describe Skill, type: :model do
  specify { expect(Skill.new.project_count).to eq(0) }

  specify { expect(Skill.new.confirmation_count).to eq(0) }
end