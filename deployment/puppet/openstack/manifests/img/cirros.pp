class openstack::img::cirros (
  $os_tenant_name = 'admin',
  $os_username = 'admin',
  $os_password = 'ChangeMe',
  $os_auth_url = 'http://127.0.0.1:5000/v2.0/',
  $disk_format = 'raw',
  $container_format = 'ovf',
  $public = 'true',
  $img_name = 'cirros',
  $os_name = 'cirros',
) {

  package { 'cirros-testvm':
    ensure => "present"
  }
  ->
  exec { 'upload-img':
    command => "/usr/bin/glance -N ${os_auth_url} -T ${os_tenant_name} -I ${os_username} -K ${os_password} add name=${img_name} is_public=${public} container_format=${container_format} disk_format=${disk_format} distro=${os_name} < /opt/vm/cirros-0.3.0-x86_64-disk.img",
    unless => "/usr/bin/glance -N ${os_auth_url} -T ${os_tenant_name} -I ${os_username} -K ${os_password} index && (/usr/bin/glance -N ${os_auth_url} -T ${os_tenant_name} -I ${os_username} -K ${os_password} index | grep ${img_name})",
    tries => 10,
    try_sleep => 3,
  }
  

}
