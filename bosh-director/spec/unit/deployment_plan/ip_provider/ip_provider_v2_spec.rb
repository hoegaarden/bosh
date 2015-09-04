require 'spec_helper'

module Bosh::Director::DeploymentPlan
  describe IpProviderV2 do

    shared_examples_for 'an ip provider with any repo' do
      let(:instance) { double(:instance, model: Bosh::Director::Models::Instance.make) }
      let(:deployment_plan) { instance_double(Planner, name: 'fake-deployment', using_global_networking?: using_global_networking) }
      let(:global_network_resolver) { instance_double(GlobalNetworkResolver, reserved_legacy_ranges: Set.new) }
      let(:vip_repo) { VipRepo.new(logger) }
      let(:manual_network_spec) {
        {
          'name' => 'my-manual-network',
          'subnets' => [
            {
              'range' => '192.168.1.0/30',
              'gateway' => '192.168.1.1',
              'dns' => ['192.168.1.1', '192.168.1.2'],
              'static' => [],
              'reserved' => [],
              'cloud_properties' => {},
              'availability_zone' => 'az-1',
            },
            {
              'range' => '192.168.2.0/30',
              'gateway' => '192.168.2.1',
              'dns' => ['192.168.2.1', '192.168.2.2'],
              'static' => [],
              'reserved' => [],
              'cloud_properties' => {},
              'availability_zone' => 'az-2',
            },
            {
              'range' => '192.168.3.0/30',
              'gateway' => '192.168.3.1',
              'dns' => ['192.168.3.1', '192.168.3.2'],
              'static' => [],
              'reserved' => [],
              'cloud_properties' => {},
              'availability_zone' => 'az-2',
            }

          ]
        }
      }
      let(:manual_network) do
        ManualNetwork.new(
          manual_network_spec,
          [
            BD::DeploymentPlan::AvailabilityZone.new('az-1', {}),
            BD::DeploymentPlan::AvailabilityZone.new('az-2', {})
          ],
          global_network_resolver,
          logger
        )
      end
      let(:vip_network_spec) {
        {
          'name' => 'my-vip-network',
          'type' => 'vip'
        }
      }
      let(:vip_network) { VipNetwork.new(vip_network_spec, logger) }
      let(:ip_reservation) { Bosh::Director::DynamicNetworkReservation.new(instance, manual_network) }

      before do
        Bosh::Director::Config.current_job = Bosh::Director::Jobs::BaseJob.new
        Bosh::Director::Config.current_job.task_id = 'fake-task-id'
      end

      describe :release do
        context 'when reservation does not have an IP' do
          it 'should raise an error' do
            expect {
              ip_provider.release(ip_reservation)
            }.to raise_error(Bosh::Director::NetworkReservationIpMissing, "Can't release reservation without an IP")
          end
        end

        context 'when reservation has an IP' do
          it 'should release IP' do
            manual_network_spec['subnets'].first['static'] = ['192.168.1.2']
            instance = double(:instance, model: Bosh::Director::Models::Instance.make, availability_zone: BD::DeploymentPlan::AvailabilityZone.new('az-2', {}))
            other_instance = double(:instance, model: Bosh::Director::Models::Instance.make, availability_zone: BD::DeploymentPlan::AvailabilityZone.new('az-2', {}))

            original_reservation = Bosh::Director::StaticNetworkReservation.new(instance, manual_network, '192.168.1.2')
            new_reservation = Bosh::Director::StaticNetworkReservation.new(other_instance, manual_network, '192.168.1.2')

            ip_provider.reserve(original_reservation)
            expect {
              ip_provider.reserve(new_reservation)
            }.to raise_error(Bosh::Director::NetworkReservationAlreadyInUse)

            ip_provider.release(original_reservation)

            expect {
              ip_provider.reserve(new_reservation)
            }.not_to raise_error
          end

          context 'when the IP is from a previous deploy and no longer in any subnets range' do
            it 'should release IP' do
              manual_network_spec['subnets'].first['range'] = '192.168.6.0/30'
              manual_network_spec['subnets'].first['gateway'] = '192.168.6.1'
              manual_network_spec['subnets'].first['dns'] = []

              reservation_with_ip_outside_subnet = Bosh::Director::StaticNetworkReservation.new(instance, manual_network, '192.168.1.2')
              expect {
                ip_provider.release(reservation_with_ip_outside_subnet)
              }.not_to raise_error
            end
          end

          context 'when VipNetwork' do
            it 'releases IP' do
              reservation = BD::StaticNetworkReservation.new(instance, vip_network, '192.168.1.2')

              ip_provider.reserve(reservation)
              expect {
                ip_provider.reserve(reservation)
              }.to raise_error

              ip_provider.release(reservation)
              expect {ip_provider.reserve(reservation)}.not_to raise_error
            end
          end
        end
      end

      describe :reserve do
        context 'when ManualNetwork' do
          context 'when IP is provided' do
            context 'when reservation does not belong to any subnet' do
              context 'when existing network reservation' do
                let(:reservation) { BD::ExistingNetworkReservation.new(instance, manual_network, '192.168.2.6') }

                it 'does not raise error' do
                  expect {
                    ip_provider.reserve(reservation)
                  }.to_not raise_error
                end
              end

              context 'when dynamic network reservation' do
                let(:reservation) { BD::DynamicNetworkReservation.new(instance, manual_network) }
                before { reservation.resolve_ip('192.168.2.6') }

                it 'raises NetworkReservationIpOutsideSubnet' do
                  expect {
                    ip_provider.reserve(reservation)
                  }.to raise_error BD::NetworkReservationIpOutsideSubnet
                end
              end

              context 'when static network reservation' do
                let(:reservation) { BD::StaticNetworkReservation.new(instance, manual_network, '192.168.2.6') }

                it 'raises NetworkReservationIpOutsideSubnet' do
                  expect {
                    ip_provider.reserve(reservation)
                  }.to raise_error BD::NetworkReservationIpOutsideSubnet
                end
              end
            end

            context 'when reservation belongs to subnet' do
              context 'when it is a dynamic reservation' do
                it 'reserves reservation' do
                  manual_network_spec['subnets'].first['range'] = '192.168.1.0/24'

                  reservation = BD::DynamicNetworkReservation.new(instance, manual_network)

                  reservation.resolve_ip('192.168.1.6')

                  allow(instance).to receive(:availability_zone).and_return(BD::DeploymentPlan::AvailabilityZone.new('az-1', {}))

                  ip_provider.reserve(reservation)
                  expect(reservation.ip).to eq(NetAddr::CIDR.create('192.168.1.6').to_i)
                  expect(reservation).to be_reserved
                end

                context 'when that IP is now in the reserved range' do
                  before do
                    manual_network_spec['subnets'].first['range'] = '192.168.1.0/24'
                    manual_network_spec['subnets'].first['reserved'] = ['192.168.1.11']
                  end

                  it 'raises an error' do
                    reservation = BD::DynamicNetworkReservation.new(instance, manual_network)
                    reservation.resolve_ip(NetAddr::CIDR.create('192.168.1.11').to_i)
                    expect {
                      ip_provider.reserve(reservation)
                    }.to raise_error Bosh::Director::NetworkReservationIpReserved,
                        "Failed to reserve IP '192.168.1.11' for network 'my-manual-network': IP belongs to reserved range"
                  end
                end

                context 'when IP is static IP' do
                  it 'raises an error' do
                    manual_network_spec['subnets'].first['static'] = ['192.168.1.2']

                    reservation = BD::DynamicNetworkReservation.new(instance, manual_network)
                    reservation.resolve_ip('192.168.1.2')
                    expect {
                      ip_provider.reserve(reservation)
                    }.to raise_error Bosh::Director::NetworkReservationWrongType,
                        "IP '192.168.1.2' on network 'my-manual-network' does not belong to dynamic pool"
                  end
                end
              end

              context 'when it is a static reservation' do
                before do
                  manual_network_spec['subnets'].first['range'] = '192.168.1.0/24'
                  manual_network_spec['subnets'].first['static'] = ['192.168.1.5']
                end
                let(:static_network_reservation) { BD::StaticNetworkReservation.new(instance, manual_network, '192.168.1.5') }

                it 'should reserve static IPs' do
                  expect {
                    ip_provider.reserve(static_network_reservation)
                  }.to_not raise_error
                end

                context 'when IP is in reserved range' do
                  before do
                    manual_network_spec['subnets'].first['range'] = '192.168.1.0/24'
                    manual_network_spec['subnets'].first['reserved'] = ['192.168.1.11']
                  end

                  it 'when IP is in reserved range, raises NetworkReservationIpReserved' do
                    reservation = BD::StaticNetworkReservation.new(instance, manual_network, '192.168.1.11')
                    expect {
                      ip_provider.reserve(reservation)
                    }.to raise_error Bosh::Director::NetworkReservationIpReserved,
                        "Failed to reserve IP '192.168.1.11' for network 'my-manual-network': IP belongs to reserved range"
                  end
                end

                context 'when IP is NOT a static IP' do
                  it 'raises an error' do
                    manual_network_spec['subnets'].first['static'] = ['192.168.1.2']
                    reservation = BD::DynamicNetworkReservation.new(instance, manual_network)
                    reservation.resolve_ip('192.168.1.2')
                    expect {
                      ip_provider.reserve(reservation)
                    }.to raise_error Bosh::Director::NetworkReservationWrongType,
                        "IP '192.168.1.2' on network 'my-manual-network' does not belong to dynamic pool"
                  end
                end
              end

              context 'when it is an existing network reservation' do
                let(:existing_network_reservation) { BD::ExistingNetworkReservation.new(instance, manual_network, '192.168.1.2') }
                context 'when IP is in the static range' do
                  it 'should reserve it as a StaticNetworkReservation' do
                    manual_network_spec['subnets'].first['static'] = ['192.168.1.2']

                    ip_provider.reserve(existing_network_reservation)

                    expect(existing_network_reservation.reserved_as?(BD::StaticNetworkReservation)).to be_truthy
                  end
                end

                context 'when IP is NOT in the static range' do
                  context 'when IP is NOT in the reserved range'
                  it 'should reserve it as a DynamicNetworkReservation' do
                    ip_provider.reserve(existing_network_reservation)

                    expect(existing_network_reservation.reserved_as?(BD::DynamicNetworkReservation)).to be_truthy
                  end
                end

                context 'when IP is in the reserved range'
                it 'should not reserve the IP' do
                  manual_network_spec['subnets'].first['reserved'] = ['192.168.1.2']

                  ip_provider.reserve(existing_network_reservation)

                  expect(existing_network_reservation).not_to be_reserved
                end
              end
            end
          end

          context 'when IP is not provided' do
            context 'for dynamic reservation' do
              let(:reservation) { BD::DynamicNetworkReservation.new(instance, manual_network) }

              it 'allocates a dynamic IP in the correct subnet when the instance has an AZ' do
                allow(instance).to receive(:availability_zone).and_return(BD::DeploymentPlan::AvailabilityZone.new('az-2', {}))
                ip_provider.reserve(reservation)

                expect(NetAddr::CIDR.create(reservation.ip).to_s).to eq('192.168.2.2/32')
              end

              it 'allocates a dynamic IP in any subnet for an instance without an AZ' do
                allow(instance).to receive(:availability_zone).and_return(nil)
                ip_provider.reserve(reservation)

                expect(NetAddr::CIDR.create(reservation.ip).to_s).to eq('192.168.1.2/32')
              end

              it 'does not allocate a static IP as a dynamic IP' do
                allow(instance).to receive(:availability_zone).and_return(nil)
                manual_network_spec['subnets'].first['static'] << '192.168.1.2'

                ip_provider.reserve(reservation)

                expect(NetAddr::CIDR.create(reservation.ip).to_s).to eq('192.168.2.2/32')
              end

              it 'does not allocate a reserved IP as a dynamic IP' do
                allow(instance).to receive(:availability_zone).and_return(nil)
                manual_network_spec['subnets'].first['reserved'] << '192.168.1.2'

                ip_provider.reserve(reservation)

                expect(NetAddr::CIDR.create(reservation.ip).to_s).to eq('192.168.2.2/32')
              end

              it 'allocates dynamic IPs across multiple subnets for a single AZ' do
                allow(instance).to receive(:availability_zone).and_return(BD::DeploymentPlan::AvailabilityZone.new('az-2', {}))
                ip_provider.reserve(BD::DynamicNetworkReservation.new(instance, manual_network))

                ip_provider.reserve(reservation)
                expect(NetAddr::CIDR.create(reservation.ip).to_s).to eq('192.168.3.2/32')
              end

              context 'when no subnet has enough capacity to allocate a dynamic IP' do
                it 'raises NetworkReservationNotEnoughCapacity' do
                  allow(instance).to receive(:availability_zone).and_return(nil)
                  # Trying to reserve 1 more IP than the available
                  3.times { ip_provider.reserve(BD::DynamicNetworkReservation.new(instance, manual_network)) }

                  expect {
                    ip_provider.reserve(reservation)
                  }.to raise_error BD::NetworkReservationNotEnoughCapacity
                end
              end
            end
          end
        end

        context 'when VipNetwork' do
          context 'when IP has already been reserved (allocated)' do
            it 'raises NetworkReservationAlreadyInUse' do
              other_instance = double(:instance, model: Bosh::Director::Models::Instance.make, availability_zone: BD::DeploymentPlan::AvailabilityZone.new('az-2', {}))
              original_static_network_reservation = BD::StaticNetworkReservation.new(instance, vip_network, '192.168.1.2')
              new_static_network_reservation = BD::StaticNetworkReservation.new(other_instance, vip_network, '192.168.1.2')

              ip_provider.reserve(original_static_network_reservation)

              expect {
                ip_provider.reserve(new_static_network_reservation)
              }.to raise_error BD::NetworkReservationAlreadyInUse
            end
          end

          context 'when IP is provided and can be reserved' do
            it 'reserves the IP as a StaticNetworkReservation' do
              reservation = BD::StaticNetworkReservation.new(instance, vip_network, '192.168.1.2')

              expect {
                ip_provider.reserve(reservation)
              }.not_to raise_error
            end
          end
        end
      end
    end

    describe 'with an in-memory repo' do
      let(:using_global_networking) { false }
      let(:ip_repo) { InMemoryIpRepo.new(logger) }
      let(:ip_provider) { IpProviderV2.new(ip_repo, vip_repo, using_global_networking, logger) }
      it_should_behave_like 'an ip provider with any repo'
    end

    describe 'with a database-backed repo' do
      let(:using_global_networking) { true }
      let(:ip_repo) { DatabaseIpRepo.new(logger) }
      let(:ip_provider) { IpProviderV2.new(ip_repo, vip_repo, using_global_networking, logger) }
      it_should_behave_like 'an ip provider with any repo'
    end
  end
end
