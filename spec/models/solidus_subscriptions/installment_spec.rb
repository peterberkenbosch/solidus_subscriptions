require 'spec_helper'

RSpec.describe SolidusSubscriptions::Installment, type: :model do
  let(:installment) { create :installment }

  it { is_expected.to validate_presence_of :subscription }

  describe '#line_item_builder' do
    subject { installment.line_item_builder }

    let(:line_items) { installment.subscription.line_items }

    it { is_expected.to be_a SolidusSubscriptions::LineItemBuilder }
    it { is_expected.to have_attributes(subscription_line_items: line_items) }
  end

  describe '#out_of_stock' do
    subject { installment.out_of_stock }

    let(:expected_date) do
      (DateTime.current + SolidusSubscriptions.configuration.reprocessing_interval).beginning_of_minute
    end

    it { is_expected.to be_a SolidusSubscriptions::InstallmentDetail }
    it { is_expected.not_to be_successful }

    it 'has the correct message' do
      expect(subject).to have_attributes(
        message: I18n.t('solidus_subscriptions.installment_details.out_of_stock')
      )
    end

    it 'advances the installment actionable_date' do
      subject
      actionable_date = installment.reload.actionable_date
      expect(actionable_date).to eq expected_date
    end
  end

  describe '#success!' do
    subject { installment.success!(order) }

    let(:order) { create :order }

    let(:installment) { create :installment, actionable_date: actionable_date }
    let(:actionable_date) { 1.month.from_now.to_date }

    it 'removes any actionable date if any' do
      expect { subject }.
        to change(installment, :actionable_date).
        from(actionable_date).to(nil)
    end

    it 'creates a new installment detail' do
      expect { subject }.
        to change { SolidusSubscriptions::InstallmentDetail.count }.
        by(1)
    end

    it 'creates a successful installment detail' do
      subject
      expect(installment.details.last).to be_successful && have_attributes(
        order: order,
        message: I18n.t('solidus_subscriptions.installment_details.success')
      )
    end
  end

  describe '#failed!' do
    subject { installment.failed!(order) }

    let(:order) { create :order }

    let(:expected_date) do
      (DateTime.current + SolidusSubscriptions.configuration.reprocessing_interval).beginning_of_minute
    end

    it { is_expected.to be_a SolidusSubscriptions::InstallmentDetail }
    it { is_expected.not_to be_successful }

    it 'has the correct message' do
      expect(subject).to have_attributes(
        message: I18n.t('solidus_subscriptions.installment_details.failed'),
        order: order
      )
    end

    it 'advances the installment actionable_date' do
      subject
      actionable_date = installment.reload.actionable_date
      expect(actionable_date).to eq expected_date
    end

    context 'the reprocessing interval is set to nil' do
      before do
        allow(SolidusSubscriptions.configuration).to receive_messages(reprocessing_interval: nil)
      end

      it 'does not advance the installment actionable_date' do
        subject
        actionable_date = installment.reload.actionable_date
        expect(actionable_date).to be_nil
      end
    end
  end

  describe '#unfulfilled?' do
    subject { installment.unfulfilled? }

    let(:installment) { create(:installment, details: details) }

    context 'the installment has an associated successful detail' do
      let(:details) { create_list :installment_detail, 1, success: true }

      it { is_expected.to be_falsy }
    end

    context 'the installment has no associated successful detail' do
      let(:details) { create_list :installment_detail, 1 }

      it { is_expected.to be_truthy }
    end
  end

  describe '#fulfilled' do
    subject { installment.fulfilled? }

    let(:installment) { create(:installment, details: details) }

    context 'the installment has an associated completed order' do
      let(:details) { create_list :installment_detail, 1, success: true }

      it { is_expected.to be_truthy }
    end

    context 'the installment has no associated completed order' do
      let(:details) { create_list :installment_detail, 1 }

      it { is_expected.to be_falsy }
    end
  end

  describe '#payment_failed!' do
    context 'when maximum_reprocessing_time is nil' do
      it 'creates a new installment detail' do
        allow(SolidusSubscriptions.configuration).to receive_messages(
          maximum_reprocessing_time: nil,
          reprocessing_interval: 2.days,
        )
        installment = create(:installment)

        installment.payment_failed!(create(:order))

        expect(installment.details.count).to eq(1)
      end

      it "advances the installment's actionable_date" do
        allow(SolidusSubscriptions.configuration).to receive_messages(
          maximum_reprocessing_time: nil,
          reprocessing_interval: 2.days,
        )
        installment = create(:installment)

        installment.payment_failed!(create(:order))

        expect(installment.actionable_date).to eq((Time.zone.now + 2.days).beginning_of_minute)
      end
    end

    context 'when maximum_reprocessing_attempts is configured' do
      context 'when the installment has surpassed the maximum reprocessing time' do
        it 'creates a new installment detail' do
          allow(SolidusSubscriptions.configuration).to receive_messages(
            maximum_reprocessing_time: 3.days,
            reprocessing_interval: 2.days,
          )
          subscription = create(:subscription)
          _last_successful_installment = create(
            :installment,
            subscription: subscription,
            details: [create(:installment_detail, :success, created_at: 4.days.ago)]
          )
          current_installment = create(:installment, subscription: subscription)
          current_installment.payment_failed!(create(:order))

          expect(current_installment.details.count).to eq(1)
        end

        it 'sets the actionable_date to nil' do
          allow(SolidusSubscriptions.configuration).to receive_messages(
            maximum_reprocessing_time: 3.days,
            reprocessing_interval: 2.days,
          )
          subscription = create(:subscription)
          _last_successful_installment = create(
            :installment,
            subscription: subscription,
            details: [create(:installment_detail, :success, created_at: 4.days.ago)]
          )
          current_installment = create(:installment, subscription: subscription)
          current_installment.payment_failed!(create(:order))

          expect(current_installment.actionable_date).to eq(nil)
        end

        it 'cancels the subscription' do
          allow(SolidusSubscriptions.configuration).to receive_messages(
            maximum_reprocessing_time: 3.days,
            reprocessing_interval: 2.days,
          )
          subscription = create(:subscription)
          _last_successful_installment = create(
            :installment,
            subscription: subscription,
            details: [create(:installment_detail, :success, created_at: 4.days.ago)]
          )
          current_installment = create(:installment, subscription: subscription)
          current_installment.payment_failed!(create(:order))

          expect(current_installment.subscription.state).to eq('canceled')
        end
      end

      context 'when the installment has not reached the maximum number of attempts' do
        it 'creates a new installment detail' do
          allow(SolidusSubscriptions.configuration).to receive_messages(
            maximum_reprocessing_time: 3.days,
            reprocessing_interval: 2.days,
          )
          subscription = create(:subscription)
          _last_successful_installment = create(
            :installment,
            subscription: subscription,
            details: [create(:installment_detail, :success, created_at: 1.day.ago)]
          )
          current_installment = create(:installment, subscription: subscription)
          current_installment.payment_failed!(create(:order))
          current_installment.payment_failed!(create(:order))

          expect(current_installment.details.count).to eq(2)
        end

        it "advances the installment's actionable_date" do
          allow(SolidusSubscriptions.configuration).to receive_messages(
            maximum_reprocessing_time: 3.days,
            reprocessing_interval: 2.days,
          )
          subscription = create(:subscription)
          _last_successful_installment = create(
            :installment,
            subscription: subscription,
            details: [create(:installment_detail, :success, created_at: 1.day.ago)]
          )
          current_installment = create(:installment, subscription: subscription)
          current_installment.payment_failed!(create(:order))

          expect(current_installment.actionable_date).to eq((Time.zone.now + 2.days).beginning_of_minute)
        end
      end
    end
  end
end
