# RUN: neut_tun.ceph.murano.sahara.ceil-controller ubuntu
# RUN: neut_tun.ceph.murano.sahara.ceil-primary-controller ubuntu
# RUN: neut_tun.ironic-primary-controller ubuntu
# RUN: neut_tun.l3ha-primary-controller ubuntu
# RUN: neut_vlan.ceph-primary-controller ubuntu
# RUN: neut_vlan.dvr-primary-controller ubuntu
# RUN: neut_vlan.murano.sahara.ceil-controller ubuntu
# RUN: neut_vlan.murano.sahara.ceil-primary-controller ubuntu

require 'spec_helper'
require 'shared-examples'
manifest = 'openstack-cinder/db.pp'

describe manifest do
  shared_examples 'catalog' do
    cinder_db_user = 'cinder'
    cinder_db_password = Noop.hiera_structure 'cinder/db_password'
    cinder_db_dbname = 'cinder'
    allowed_hosts = ['localhost','127.0.0.1','%']

    it 'should install proper mysql-client' do
      if facts[:osfamily] == 'RedHat'
        pkg_name = 'MySQL-client-wsrep'
      elsif facts[:osfamily] == 'Debian'
        pkg_name = 'mysql-client-5.6'
      end
      should contain_class('mysql::client').with(
        'package_name' => pkg_name,
      )
    end

    it 'should declare cinder::db::mysql class with user,password,dbname' do
      should contain_class('cinder::db::mysql').with(
        'user' => cinder_db_user,
        'password' => cinder_db_password,
        'dbname' => cinder_db_dbname,
        'allowed_hosts' => allowed_hosts,
      )
    end
    allowed_hosts.each do |host|
      it "should define openstacklib::db::mysql::host_access for #{cinder_db_dbname} DB for #{host}" do
        should contain_openstacklib__db__mysql__host_access("#{cinder_db_dbname}_#{host}")
      end
    end
  end # end of shared_examples
  test_ubuntu_and_centos manifest
end

