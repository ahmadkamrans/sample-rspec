RSpec.describe Users::RegisterUser do

  subject { Users::RegisterUser.call(user: user) }

  let(:user) { build(:user) }

  around(:each) do |group|
    Sidekiq::Testing.inline! { group.run }
  end

  shared_examples_for "runs successfully" do
    it "runs successfully" do
      is_expected.to be_success
    end
  end

  context "when there is no user" do
    let(:user) { nil }

    it { is_expected.to be_failure }
  end

  context "when user is a business owner" do
    let(:business) { build(:business) }
    it "syncs to crm" do
      user.business = business
      expect_any_instance_of(Business).to receive(:add_to_crm)

      subject
    end
  end
end
