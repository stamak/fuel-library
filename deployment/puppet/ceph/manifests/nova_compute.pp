# configure the nova_compute parts if present
class ceph::nova_compute (
  $rbd_secret_uuid     = $::ceph::rbd_secret_uuid,
  $user                = $::ceph::compute_user,
  $compute_pool        = $::ceph::compute_pool,
  $secret_xml          = '/root/.secret_attrs.xml',
) {

  include ::nova::params

  file { $secret_xml:
    mode    => '0400',
    content => template('ceph/secret.erb')
  }

  ensure_resource('service', 'libvirt', {
    ensure => 'running',
    name   => $::nova::params::libvirt_service_name,
  })

  exec {'Set Ceph RBD secret for Nova':
    # TODO: clean this command up
    command => "virsh secret-define --file ${secret_xml} && \
      virsh secret-set-value --secret ${rbd_secret_uuid} \
      --base64 $(ceph auth get-key client.${user})",
    unless => "virsh secret-list | fgrep -qw ${rbd_secret_uuid}",
  }

  nova_config {
    'libvirt/rbd_secret_uuid':          value => $rbd_secret_uuid;
    'libvirt/rbd_user':                 value => $user;
  }

  File[$secret_xml] ->
  Service['libvirt'] -> Exec['Set Ceph RBD secret for Nova']
}
