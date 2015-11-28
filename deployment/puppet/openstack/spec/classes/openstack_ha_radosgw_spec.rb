require 'spec_helper'

  describe 'openstack::ha::radosgw' do
    let(:params) { {:internal_virtual_ip  => '127.0.0.1',
                    :ipaddresses          => ['127.0.0.2', '127.0.0.3'],
                    :public_virtual_ip    => '192.168.0.1',
                    :baremetal_virtual_ip => '192.168.0.2',
                    :server_names         => ['node-1', 'node-2'],
                    :public_ssl           => true,
                 } }
    let(:facts) { {:kernel => 'Linux',
                   :concat_basedir => '/var/lib/puppet/concat',
                   :fqdn           => 'some.host.tld'
                } }

    it "should properly configure radosgw haproxy based on ssl" do
      should contain_openstack__ha__haproxy_service('radosgw').with(
        'order'                  => '130',
        'listen_port'            => 8080,
        'balancermember_port'    => 6780,
        'public'                 => true,
        'public_ssl'             => true,
        'haproxy_config_options' => {
          'option'       => ['httplog', 'httpchk GET /'],
          'http-request' => 'set-header X-Forwarded-Proto https if { ssl_fc }',
        },
      )
    end

    it "should properly configure radosgw haproxy on baremetal VIP" do
      should contain_openstack__ha__haproxy_service('radosgw-baremetal').with(
        'order'                  => '135',
        'listen_port'            => 8080,
        'balancermember_port'    => 6780,
        'public_virtual_ip'      => false,
        'internal_virtual_ip'    => '192.168.0.2',
        'haproxy_config_options' => {
          'option'       => ['httplog', 'httpchk GET /'],
          'http-request' => 'set-header X-Forwarded-Proto https if { ssl_fc }',
        },
      )
    end
  end