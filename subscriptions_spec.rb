RSpec.describe Admin::SubscriptionsController, type: :request do

  before(:each) { allow_any_instance_of(User).to receive(:mfa_session_exists?).and_return(true) }

  around(:each) do |group|
    @business = create(:business, business_name: "Fake Hairdresser")
    signed_in_as(:super_admin_user) { group.run }
  end

  before(:each) do
    # This is easier than stubbing the elasticsearch query called by Business#implied_locations, or setting up elasticsearch
    # in the test environment.
    @location = create(:location)
    allow_any_instance_of(Business).to receive(:implied_locations).and_return(Location.where(id: @location.id))
  end

  describe "#new" do
    subject do
      get "/admin/businesses/fake-hairdresser/subscriptions/new"
    end

    it "is successful" do
      subject

      expect(response).to be_successful
    end

    it "assigns the business to @business" do
      subject

      expect(assigns(:business)).to eq(@business)
    end

    it "assigns a new subscription for the business to @business" do
      subject

      expect(assigns(:subscription)).to be_a(Subscription)
      expect(assigns(:subscription).business).to eq(@business)
      expect(assigns(:subscription)).not_to be_persisted
    end

    context "when there is an error with Elasticsearch computing the suburbs in coverage area" do
      before(:each) do
        allow_any_instance_of(Business).to receive(:latest_monthly_rrp).
          and_raise(Elasticsearch::Transport::Transport::Errors::BadGateway)
      end

      it "renders a message explaining the error" do
        subject

        expect(response.body).to include("Error calculating RRP")
      end
    end
  end

  describe "#create" do
    subject do
      post "/admin/businesses/fake-hairdresser/subscriptions", params
    end

    let(:params) { valid_params }

    let(:valid_params) do
      plan_id = APP_CONFIG.hcp.default_yearly_product_id
      {
        business_id: @business,
        subscription: { plan_id: plan_id, amount: 100, paid_by_business_id: @business.id },
        cc: valid_cc_params
      }
    end

    context "with valid params" do
      # it "signs up the Business to the HCP" do
      #   expect { subject }.to change { @business.reload.hcp? }.to(true)
      # end

      # it "creates four Cases" do
      #   expect { subject }.to change(Case, :count).by(4)
      # end

      # it "creates a new Subscription" do
      #   expect { subject }.to change { @business.reload.subscriptions.count }.by(1)
      #   subscription = @business.subscriptions.first
      #   expect(subscription.deal_id).to eq(deal_id)
      # end

      # it "charges the credit card" do
      #   expect(GATEWAY).to receive(:purchase).and_call_original

      #   subject
      # end

      # it "creates a Payment record" do
      #   expect { subject }.to change(Payment, :count).by(1)
      # end

      # it "redirects to the subscriptions tab for the business" do
      #   subject

      #   expect(response).to redirect_to("/admin/businesses/fake-hairdresser/edit#subscription")
      # end

      context "when credit card on file is selected" do
        let(:params) do
          plan_id = APP_CONFIG.hcp.default_yearly_product_id
          valid_params.merge(
            subscription: { plan_id: plan_id, amount: 100, paid_by_business_id: @business.id, payment_method: "cc_on_file" }
          )
        end
        let!(:credit_card) { create(:credit_card, business: @business) }

        it "uses the credit card on file" do
          expect { subject }.to change { @business.reload.subscriptions.count }.by(1)
        end
      end

      context "when the business is not associated with any categories" do
        it "does not create a subscription_price_component" do
          expect { subject }.not_to change(SubscriptionPriceComponent, :count)
        end
        let!(:credit_card) { create(:credit_card, business: @business) }

        it "still charges the credit card" do
          expect(::Payments::PaymentIntent).to receive(:call).and_call_original

          subject
        end

        it "still creates a Payment record" do
          expect { subject }.to change(Payment, :count).by(1)
        end
      end

      context "when the business is associated with exactly one category" do
        context "when the category is active and has an associated price" do
          before(:each) do
            @category = create(:category, archived: false)
            create(:business_category, business: @business, category: @category)
            create(:credit_card, business: @business)
          end

          let!(:active_price_component) do
            create(:price_component, category: @category, location: @location)  # old price component
            create(:price_component, category: @category, location: @location)  # active price component
          end

          it "creates a SubscriptionPriceComponent linked to the active PriceComponent for that category" do
            expect { subject }.to change(SubscriptionPriceComponent, :count).by(1)

            @business.reload
            expect(@business.subscriptions.count).to eq(1)
            subscription = @business.subscriptions.first
            expect(subscription.subscription_price_components.count).to eq(1)
            expect(subscription.subscription_price_components.first.price_component).to eq(active_price_component)
          end

          it "charges the credit card" do
            expect(::Payments::PaymentIntent).to receive(:call).and_call_original

            subject
          end

          it "creates a Payment record" do
            expect { subject }.to change(Payment, :count).by(1)
          end

          context "when there is an error creating SubscriptionPriceComponents" do
            shared_examples_for "abort with error" do
              it "does not charge the credit card" do
                expect(::Payments::PaymentIntent).not_to receive(:call)

                subject
              end

              it "does not create a Payment record" do
                expect { subject }.not_to change(Payment, :count)
              end

              it "does not change the business to an HCP" do
                expect { subject }.not_to change { @business.reload.hcp? }
              end

              it "renders an error message", :aggregate_failures do
                subject

                body = response.body
                expect(body).to include("Subscription has not been created")
                expect(body).to include("payment has not been recorded")
                expect(body).to include("business has not been charged")
              end

              it "logs the error to Rollbar" do
                # sometimes fired a second time on new form render -- which is fine.
                expect(Rollbar).to receive(:error).at_least(1).times

                subject
              end
            end

            context "when the error is due to a failure with Elasticsearch when computing of suburbs in coverage area" do
              before(:each) do
                times = 0
                allow_any_instance_of(Business).to receive(:implied_locations).and_raise(elasticsearch_error)
              end

              context "when Elasticsearch::Transport::Transport::Errors::InternalServerError is raised" do
                let(:elasticsearch_error) { Elasticsearch::Transport::Transport::Errors::InternalServerError }

                it_behaves_like "abort with error"
              end

              context "when Elasticsearch::Transport::Transport::Errors::BadGateway is raised" do
                let(:elasticsearch_error) { Elasticsearch::Transport::Transport::Errors::BadGateway }

                it_behaves_like "abort with error"
              end

              context "when Elasticsearch::Transport::Transport::Errors::ServiceUnavailable is raised" do
                let(:elasticsearch_error) { Elasticsearch::Transport::Transport::Errors::ServiceUnavailable }

                it_behaves_like "abort with error"
              end
            end

            context "when the error is for some other reason" do
              before(:each) do
                subscription_price_component = double("subscription_price_component", persisted?: false,
                  errors: ActiveModel::Errors.new("hahaha"))
                allow_any_instance_of(Subscription).to receive(:subscription_price_components).
                  and_return(double("subscription_price_components", create: subscription_price_component))
              end

              it_behaves_like "abort with error"
            end
          end
        end

        context "when the category is active but does not have an associated price" do
          it "does not create a SubscriptionPriceComponent" do
            expect { subject }.not_to change { SubscriptionPriceComponent.count }
          end
        end

        context "when the category has an associated price but is inactive" do
          before(:each) do
            @inactive_category = create(:category, archived: true)
            create(:business_category, business: @business, category: @inactive_category)
            create(:credit_card, business: @business)
          end

          it "does not create a SubscriptionPriceComponent" do
            price_component = create(:price_component, category: @inactive_category, location: Location.first)

            expect { subject }.not_to change(SubscriptionPriceComponent, :count)
          end

          it "still charges the credit card" do
            expect(::Payments::PaymentIntent).to receive(:call).and_call_original

            subject
          end

          it "still creates a Payment record" do
            expect { subject }.to change(Payment, :count).by(1)
          end
        end
      end

      context "when the business is associated with multiple categories" do
        before(:each) do
          @priced_category_a = create(:category, archived: false)
          create(:business_category, business: @business, category: @priced_category_a)
          @priced_category_b = create(:category, archived: false)
          create(:business_category, business: @business, category: @priced_category_b)
          @unpriced_category = create(:category, archived: false)
          create(:business_category, business: @business, category: @unpriced_category)
          @inactive_category = create(:category, archived: true)
          create(:business_category, business: @business, category: @inactive_category)
          create(:credit_card, business: @business)
        end

        it "creates a subscription_price_component linked to the active price_component for each associated active "\
          "priced category / location pair" do
          unused_location = create(:location, id: 1_000_001)
          _old_pc_0 = create(:price_component, category: @priced_category_a, location: @location)
          pc_0 = create(:price_component, category: @priced_category_a, location: @location)
          pc_1 = create(:price_component, category: @priced_category_b, location: @location)
          _inactive_pc = create(:price_component, category: @inactive_category, location: @location)
          _wrong_location_pc = create(:price_component, category: @priced_category_b, location: unused_location)

          expect {
            post "/admin/businesses/fake-hairdresser/subscriptions", valid_params
          }.to change { SubscriptionPriceComponent.count }.from(0).to(2)

          @business.reload
          expect(@business.subscriptions.count).to eq(1)
          subscription = @business.subscriptions.first
          expect(subscription.subscription_price_components.count).to eq(2)
          expect(subscription.subscription_price_components.map(&:price_component)).to match_array([pc_0, pc_1])
        end

        it "charges the credit card" do
          expect(::Payments::PaymentIntent).to receive(:call).and_call_original

          subject
        end

        it "creates a successful Payment record" do
          expect { subject }.to change { Payment.where(current_state: "success").count }.by(1)
        end

        it "does not create a failed Payment record" do
          expect { subject }.not_to change { Payment.where(current_state: "failed").count }
        end
      end

    end

    context "when the credit card payment bounces" do
      before do
        response_a = double("response_a", success?: true,
                              params: { "Customer" => {
                                          "TokenCustomerID" => "foo",
                                          "CardDetails" => {
                                            "Number" => "1111",
                                            "ExpiryMonth" => valid_cc_params[:month],
                                            "ExpiryYear" => valid_cc_params[:year]
                                          }
                                        }
                                      })
        allow(GATEWAY).to receive(:store).and_return(response_a)
        allow(GATEWAY).to receive(:update).and_return(response_a)
        response_b = double("response_b", success?: false, message: "a", params: { message: "a", transaction_number: "b" })
        allow(GATEWAY).to receive(:purchase).and_return(response_b)
      end

      it "does not create a new Subscription" do
        expect { subject }.not_to change(Subscription, :count)
      end

      it "does not create any SubscriptionPriceComponents" do
        expect { subject }.not_to change(SubscriptionPriceComponent, :count)
      end

      it "does not create a Payment record" do
        expect { subject }.not_to change(Payment, :count)
      end
    end
  end

  describe "#edit" do
    before(:each) do
      @subscription = create(%i(monthly_subscription yearly_subscription).sample, business: @business, id: 500)
      get "/admin/businesses/fake-hairdresser/subscriptions/500/edit"
    end

    it "is successful" do
      expect(response).to be_successful
    end

    it "assigns to @subscription" do
      expect(assigns(:subscription)).to eq(@subscription)
    end

    it "contains a link to the dialog for recording a direct deposit payment" do
      expect(response.body).to include('href="#modal-direct-deposit"')
    end
  end

  describe "#update" do
    let(:plan) { create(:plan) }
    it "updates the next_renewal_at date" do
      subscription = create(%i(monthly_subscription yearly_subscription).sample, id: 500, business: @business,
        next_renewal_at: Time.zone.parse("2017-12-20"), plan: plan)

      expect_any_instance_of(Business).to receive(:sync_to_crm).with(
        fields: hash_including(wom_next_renewal_at: Time.zone.parse("2020-12-20"))
      )

      expect {
        put(
          "/admin/businesses/fake-hairdresser/subscriptions/500",
          subscription: { next_renewal_at: "2020-12-20" }
        )
      }.to change { subscription.reload.next_renewal_at }.to(Time.zone.parse("2020-12-20"))
    end
  end

  pending "#direct_deposit"

  describe "#update_sales_rep" do
    before(:each) do
      @old_sales_rep = create(:super_admin_user)
      @new_sales_rep = create(:super_admin_user)
      @subscription = create(:subscription, business: @business, sales_rep: @old_sales_rep)
    end

    context "with valid sales_rep_id" do
      before(:each) do
        put "/admin/businesses/#{@business.id}/subscriptions/#{@subscription.id}/update_sales_rep",
          sales_rep_id: @new_sales_rep.id, format: :json
      end

      it "updates the subscription's sales rep" do
        expect(@subscription.reload.sales_rep).to eq(@new_sales_rep)
      end

      it "renders JSON with a success message" do
        expect(response.body).to eq('{"result":"success","message":"Updated."}')
      end
    end

    context "with nil sales_rep_id" do
      before(:each) do
        put "/admin/businesses/#{@business.id}/subscriptions/#{@subscription.id}/update_sales_rep",
          sales_rep_id: nil, format: :json
      end

      it "clears the subscription's sales rep" do
        expect(@subscription.reload.sales_rep).to be_nil
      end

      it "renders JSON with a success message" do
        expect(response.body).to eq('{"result":"success","message":"Updated."}')
      end
    end

    context "with invalid sales_rep_id" do
      before(:each) do
        put "/admin/businesses/#{@business.id}/subscriptions/#{@subscription.id}/update_sales_rep",
          sales_rep_id: 5000, format: :json
      end

      it "does not change the subscription's sales rep" do
        expect(@subscription.reload.sales_rep).to eq(@old_sales_rep)
      end

      it "renders JSON with an error message" do
        expect(response.body).to eq('{"result":"error","message":"Something went wrong. Subscription has not been updated."}')
      end
    end
  end
end
