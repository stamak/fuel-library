# RUN: neut_tun.ceph.murano.sahara.ceil-mongo ubuntu
# RUN: neut_tun.ceph.murano.sahara.ceil-primary-mongo ubuntu
# RUN: neut_vlan.murano.sahara.ceil-mongo ubuntu
# RUN: neut_vlan.murano.sahara.ceil-primary-mongo ubuntu
# RUN: neut_vlan.murano.sahara.ceil-cinder ubuntu
# RUN: neut_tun.ironic-ironic ubuntu
# RUN: neut_tun.ceph.murano.sahara.ceil-ceph-osd ubuntu
# RUN: neut_vlan.ceph-ceph-osd ubuntu
# RUN: neut_tun.ceph.murano.sahara.ceil-controller ubuntu
# RUN: neut_tun.ceph.murano.sahara.ceil-primary-controller ubuntu
# RUN: neut_tun.ironic-primary-controller ubuntu
# RUN: neut_tun.l3ha-primary-controller ubuntu
# RUN: neut_vlan.ceph-primary-controller ubuntu
# RUN: neut_vlan.dvr-primary-controller ubuntu
# RUN: neut_vlan.murano.sahara.ceil-controller ubuntu
# RUN: neut_vlan.murano.sahara.ceil-primary-controller ubuntu
# RUN: neut_tun.ceph.murano.sahara.ceil-compute ubuntu
# RUN: neut_vlan.ceph-compute ubuntu
# RUN: neut_vlan.murano.sahara.ceil-compute ubuntu
# R_N: neut_gre.generate_vms ubuntu
require 'spec_helper'
require 'shared-examples'
manifest = 'firewall/firewall.pp'

describe manifest do
  shared_examples 'catalog' do

    let(:network_scheme) do
      Noop.hiera_hash 'network_scheme', {}
    end

    let(:prepare) do
      Noop.puppet_function 'prepare_network_config', network_scheme
    end

    let(:management_nets) do
      Noop.puppet_function 'get_routable_networks_for_network_role', network_scheme, 'management'
    end

    let(:storage_nets) do
      Noop.puppet_function 'get_routable_networks_for_network_role', network_scheme, 'storage'
    end

    let(:database_network) do
      Noop.puppet_function 'get_routable_networks_for_network_role', network_scheme, 'mgmt/database'
    end

    let(:keystone_network) do
      Noop.puppet_function 'get_routable_networks_for_network_role', network_scheme, 'keystone/api'
    end

    let(:baremetal_network) do
      prepare
      Noop.puppet_function 'get_network_role_property', 'ironic/baremetal', 'network'
    end

    let(:baremetal_ipaddr) do
      prepare
      Noop.puppet_function 'get_network_role_property', 'ironic/baremetal', 'ipaddr'
    end

    node_name = Noop.hiera('node_name')
    network_metadata = Noop.hiera_hash 'network_metadata', {}
    roles = network_metadata['nodes'][node_name]['node_roles']
    mongodb_port = Noop.hiera('mongodb_port', '27017')

    if Noop.puppet_function 'member', roles, 'primary-controller' or Noop.puppet_function 'member', roles, 'controller'
      it 'should properly restrict rabbitmq admin traffic' do
        should contain_firewall('005 local rabbitmq admin').with(
          'sport'   => [ 15672 ],
          'iniface' => 'lo',
          'proto'   => 'tcp',
          'action'  => 'accept'
        )
        should contain_firewall('006 reject non-local rabbitmq admin').with(
          'sport'   => [ 15672 ],
          'proto'   => 'tcp',
          'action'  => 'drop'
        )
      end

      it 'should accept connections to mysql using network with mgmt/database role' do
        should contain_openstack__firewall__multi_net('101 mysql').with(
          'port'        => [ 3306, 3307, 4567, 4568, 4444, 49000 ],
          'proto'       => 'tcp',
          'action'      => 'accept',
          'source_nets' => database_network,
        )
      end

      it 'should accept connections to keystone API using network with keystone/api role' do
        should contain_openstack__firewall__multi_net('102 keystone').with(
          'port'        => [ 5000, 35357 ],
          'proto'       => 'tcp',
          'action'      => 'accept',
          'source_nets' => keystone_network,
        )
      end

      it 'should accept connections to nova' do
        should contain_firewall('105 nova').with(
          'port'        => [ 8774, 8776, 6080 ],
          'proto'       => 'tcp',
          'action'      => 'accept',
        )
      end

      it 'should accept connections to nova without ssl' do
        management_nets.each do |source|
          should contain_firewall("105 nova internal - no ssl from #{source}").with(
            'port'        => [ 8775, '5900-6100' ],
            'proto'       => 'tcp',
            'action'      => 'accept',
            'source'      => source,
          )
        end
      end

      it 'should accept connections to iscsi' do
        storage_nets.each do |source|
          should contain_firewall("109 iscsi from #{source}").with(
            'port'        => [ 3260 ],
            'proto'       => 'tcp',
            'action'      => 'accept',
            'source'      => source,
          )
        end
      end

      it 'should create rules for murano rabbitmq port' do
        should contain_firewall('203 murano-rabbitmq').with(
          'dport'    => [ 55572 ],
          'proto'   => 'tcp',
          'action'  => 'accept',
        )
      end

      it 'should create rules for heat' do
        should contain_firewall('204 heat-api').with(
          'port'    => [ 8004 ],
          'proto'   => 'tcp',
          'action'  => 'accept',
        )
        should contain_firewall('205 heat-api-cfn').with(
          'port'    => [ 8000 ],
          'proto'   => 'tcp',
          'action'  => 'accept',
        )
        should contain_firewall('206 heat-api-cloudwatch').with(
          'port'    => [ 8003 ],
          'proto'   => 'tcp',
          'action'  => 'accept',
        )
      end

      it 'should accept connections from 240.0.0.2' do
        should contain_firewall('030 allow connections from haproxy namespace').with(
          'source'      => '240.0.0.2',
          'action'      => 'accept',
        )
      end
    elsif Noop.puppet_function 'member', roles, 'compute'
      it 'should accept connections to nova without ssl' do
        management_nets.each do |source|
          should contain_firewall("105 nova vnc from #{source}").with(
            'port'        => [ '5900-6100' ],
            'proto'       => 'tcp',
            'action'      => 'accept',
            'source'      => source,
          )
        end
      end

      it 'should accept connections to libvirt' do
        management_nets.each do |source|
          should contain_firewall("118 libvirt from #{source}").with(
            'port'        => [ 16509 ],
            'proto'       => 'tcp',
            'action'      => 'accept',
            'source'      => source,
          )
        end
      end

      it 'should allow libvirt vm migration' do
        management_nets.each do |source|
          should contain_firewall("119 libvirt-migration from #{source}").with(
            'port'        => [ '49152-49215' ],
            'proto'       => 'tcp',
            'action'      => 'accept',
            'source'      => source,
          )
        end
      end
    elsif Noop.puppet_function 'member', roles, 'primary-mongo' or Noop.puppet_function 'member', roles, 'mongo'
      it 'should create firewall rules' do
        should contain_firewall('120 mongodb').with('port' => mongodb_port)
      end
    end

    if Noop.hiera_structure 'ironic/enabled'
      if Noop.hiera('role') == 'controller' or Noop.hiera('role') == 'primary-controller'
        it 'should drop all traffic from baremetal network' do
          should contain_firewall('999 drop all baremetal').with(
            'chain'  => 'baremetal',
            'proto'  => 'all',
            'action' => 'drop',
          )
        end
        it 'should enable 6385 ironic-api port' do
            should contain_firewall('207 ironic-api').with(
              'dport'   => '6385',
              'proto'   => 'tcp',
              'action'  => 'accept'
            )
        end
      end

      if Noop.hiera('role') == 'ironic'
        it 'should create rules for ironic on conductor' do
          should contain_firewall('102 allow baremetal-rsyslog').with(
            'chain'       => 'baremetal',
            'dport'       => [ 514 ],
            'proto'       => 'udp',
            'action'      => 'accept',
            'source'      => baremetal_network,
            'destination' => baremetal_ipaddr,
          )
          should contain_firewall('103 allow baremetal-TFTP').with(
            'chain'       => 'baremetal',
            'dport'       => [ 69 ],
            'proto'       => 'udp',
            'action'      => 'accept',
            'source'      => baremetal_network,
            'destination' => baremetal_ipaddr,
          )
        end
      end
    end
  end

  test_ubuntu_and_centos manifest
end

