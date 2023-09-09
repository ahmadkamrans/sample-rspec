RSpec.describe Users::UpdateTrustFactor do

  subject { Users::UpdateTrustFactor.call(user: user) }

  let!(:user) { create(:user, trust_factor: 0) }

  around(:each) do |group|
    Sidekiq::Testing.inline! { group.run }
  end

  before do
    allow(CRM::SyncWorker).to receive(:perform_async).and_return(true)
  end

  shared_examples_for "runs successfully" do
    it "runs successfully" do
      is_expected.to be_success
    end
  end

  context "even when there is no user" do
    let(:user) { nil }

    it_behaves_like "runs successfully"
  end

  context "when no trust factor increase has been earned" do
    it_behaves_like "runs successfully"

    context "when there are unretracted reviews with a negative rating" do
      before(:each) { create(:review, user: user, current_state: :negative_rating, retracted: false) }

      it "does not publish those reviews" do
        expect { subject }.not_to change { user.reload.reviews.public_view.count }.from(0)
      end

      it "does not email the customer" do
        allow(UserMailer).to receive(:delay).and_return(UserMailer)
        expect(UserMailer).not_to receive(:review_published)

        subject
      end
    end

  end

  context "when trust factor increase to 60+ has been earned by email verifications etc.." do
    before(:each) { user.update!(email_verified: true, mobile_verified: true) }

    it_behaves_like "runs successfully"

    context "when there are unretracted reviews with a negative rating" do
      let(:review) { create(:review, user: user, current_state: :negative_rating, retracted: false) }
      before(:each) { review }

      it "publishes those reviews" do
        expect { subject }.to change { user.reload.reviews.public_view.count }.by(1)
      end

      it "emails the customer notifying them that their review has been published" do
        allow(UserMailer).to receive(:delay).and_return(UserMailer)
        expect(UserMailer).to receive(:review_published).with(review.id)

        subject
      end
    end
  end

  context "when user mobile has been verified" do
    before(:each) { user.update!(mobile_verified: true) }

    it "increases trust factor by 20" do
      expect { subject }.to change { user.reload.trust_factor }.by(20)
    end
  end

  context "when user email has been verified" do
    before(:each) { user.update!(email_verified: true) }

    it "increases trust factor by 50" do
      expect { subject }.to change { user.reload.trust_factor }.by(50)
    end
  end

  context "when user Facebook ID has been provided" do
    before(:each) { user.update!(facebook_id: "alksdjfalsdkfj") }

    it "increases trust factor by 20" do
      expect { subject }.to change { user.reload.trust_factor }.by(20)
    end
  end

  context "when user trust factor would otherwise exceed 100" do
    before(:each) do
      create_list(:review, 5, user: user, overall_rating: 5)
      user.update!(mobile_verified: true, email_verified: true, facebook_id: "laskdjflsk")
    end

    it "only limits trust factor to 100" do
      expect { subject }.to change { user.reload.trust_factor }.to(100)
    end
  end
end
