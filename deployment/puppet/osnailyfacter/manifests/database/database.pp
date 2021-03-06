class osnailyfacter::database::database {

  notice('MODULAR: database/database.pp')

  $network_scheme = hiera_hash('network_scheme', {})
  prepare_network_config($network_scheme)
  $network_metadata = hiera_hash('network_metadata', {})
  $use_syslog               = hiera('use_syslog', true)
  $primary_controller       = hiera('primary_controller')
  $mysql_hash               = hiera_hash('mysql', {})
  $management_vip           = hiera('management_vip')
  $database_vip             = hiera('database_vip', $management_vip)

  $mgmt_iface = get_network_role_property('mgmt/database', 'interface')
  $direct_networks = split(direct_networks($network_scheme['endpoints'], $mgmt_iface, 'netmask'), ' ')
  # localhost is covered by mysql::server so we use this for detached db
  $access_networks = flatten(['240.0.0.0/255.255.0.0', $direct_networks])

  $haproxy_stats_port   = '10000'
  $haproxy_stats_url    = "http://${database_vip}:${haproxy_stats_port}/;csv"

  $mysql_database_password   = $mysql_hash['root_password']
  $enabled                   = pick($mysql_hash['enabled'], true)

  $galera_node_address       = get_network_role_property('mgmt/database', 'ipaddr')
  $galera_nodes              = values(get_node_to_ipaddr_map_by_network_role(hiera_hash('database_nodes'), 'mgmt/database'))
  $galera_primary_controller = hiera('primary_database', $primary_controller)
  $galera_cluster_name       = 'openstack'

  $mysql_skip_name_resolve  = true
  $custom_setup_class       = hiera('mysql_custom_setup_class', 'galera')

  # Get galera gcache factor based on cluster node's count
  $galera_gcache_factor     = count(keys($network_metadata['nodes']))
  # FIXME(dbilunov): enable binary logs to avoid mysqld crashes (LP#1541338).
  # Revert this option to false after the upstream bug is resolved.
  # https://github.com/codership/mysql-wsrep/issues/112
  $mysql_binary_logs        = hiera('mysql_binary_logs', true)
  $log_bin                  = pick($mysql_hash['log_bin'], 'mysql-bin')
  $expire_logs_days         = pick($mysql_hash['expire_logs_days'], '1')
  $max_binlog_size          = pick($mysql_hash['max_binlog_size'], '64M')

  $status_user              = 'clustercheck'
  $status_password          = $mysql_hash['wsrep_password']
  $backend_port             = '3307'
  $backend_timeout          = '10'

  $external_lb = hiera('external_lb', false)

  #############################################################################
  validate_string($status_password)
  validate_string($mysql_database_password)
  validate_string($status_password)

  if $enabled {

    if '/var/lib/mysql' in $::mounts {
      $ignore_db_dir_options = {
        'mysqld'          => {
          'ignore-db-dir' => ['lost+found'],
        }
      }
    } else {
      $ignore_db_dir_options = {}
    }

    case $custom_setup_class {
      'percona': {
        # percona provided by OS is the default from the galera module
        $vendor_type = 'percona'
        $mysql_package_name = undef
        $galera_package_name = undef
        $client_package_name = undef
        $mysql_socket = '/var/lib/mysql/mysql.sock'
      }
      'percona_packages': {
        # percona provided by percona
        $vendor_type = 'percona'
        case $::osfamily {
          'Debian': {
            $mysql_package_name = 'percona-xtradb-cluster-server-5.6'
            $galera_package_name = 'percona-xtradb-cluster-galera-3.x'
            $client_package_name = 'percona-xtradb-cluster-client-5.6'
            $libgalera_prefix = '/usr/lib/galera3'
            $mysql_socket = '/var/run/mysqld/mysqld.sock'
          }
          'RedHat': {
            $mysql_package_name = 'Percona-XtraDB-Cluster-server-56'
            $galera_package_name = 'Percona-XtraDB-Cluster-galera-4'
            $client_package_name = 'Percona-XtraDB-Cluster-client-56'
            $libgalera_prefix = '/usr/lib64/galera3'
            $mysql_socket = '/var/lib/mysql/mysql.sock'
            # This is a work around to prevent the conflict between the
            # MySQL-shared-wsrep package (included as a dependency for
            # MySQL-python) and the Percona shared package
            # Percona-XtraDB-Cluster-shared-56. They both
            # provide the libmysql client libraries. Since we are requiring the
            # installation of the Percona package here before mysql::python, the
            # python client is happy and the server installation won't fail due
            # to the installation of our shared package
            package { 'Percona-XtraDB-Cluster-shared-56':
              ensure => 'present',
              before => Class['::mysql::bindings'],
            }
          }
          default: { fail('unsupported os for percona_packages') }

        }
        $vendor_override_options = {
          'mysqld'           => {
            'wsrep_provider' => "${libgalera_prefix}/libgalera_smm.so"
          }
        }
      }
      default: {
        # MOS galera packages
        $vendor_type = 'MOS'
        $mysql_package_name = 'mysql-server-wsrep-5.6'
        $galera_package_name = 'galera-3'
        $client_package_name = 'mysql-client-5.6'
        $vendor_override_options = {
          'mysqld'           => {
            'wsrep_provider' => '/usr/lib/galera/libgalera_smm.so'
          }
        }
        $mysql_socket = '/var/run/mysqld/mysqld.sock'
      }
    }

    $gcache_size = inline_template("<%= [256, ${::galera_gcache_factor}*64, 2048].sort[1] %>M")
    $wsrep_group_comm_port = '4567'
    if $::memorysize_mb < 4000 {
      $mysql_performance_schema = 'off'
    } else {
      $mysql_performance_schema = 'on'
    }
    $innodb_buffer_pool_size = inline_template("<%= [(${::memorysize_mb} * 0.2 + 0).floor, 10000].min %>")
    $innodb_log_file_size    = inline_template("<%= [(${innodb_buffer_pool_size} * 0.2 + 0).floor, 2047].min %>")
    $key_buffer_size         = 64
    $sort_buffer_size_mb     = '0.25'
    $read_buffer_size_mb     = '0.125'
    $max_connections = inline_template(
            "<%= [[((${::memorysize_mb} * 0.3 - ${key_buffer_size}) /
             (${sort_buffer_size_mb} + ${read_buffer_size_mb})).floor, 8192].min, 2048].max %>")

    $wsrep_provider_options = "\"gcache.size=${gcache_size}; gmcast.listen_addr=tcp://${galera_node_address}:${wsrep_group_comm_port}\""
    $wsrep_slave_threads = inline_template("<%= [[${::processorcount}*2, 4].max, 12].min %>")

    if $use_syslog {
      $syslog_options = {
        'mysqld_safe'                    => {
          'syslog'                       => true,
          'log-error'                    => undef
        },
        'mysqld'                         => {
          'log-error'                    => undef
        },
      }
    }

    # this is configurable via hiera
    if $mysql_binary_logs {
      $binary_logs_options = {
        'mysqld'                         => {
          'log_bin'                      => $log_bin,
          'expire_logs_days'             => $expire_logs_days,
          'max_binlog_size'              => $max_binlog_size,
        },
      }
    }

    $fuel_override_options = {
      'mysqld'                           => {
        'port'                           => $backend_port,
        'max_connections'                => $max_connections,
        'pid-file'                       => undef,
        'expire_logs_days'               => undef,
        'log_bin'                        => undef,
        'collation-server'               => 'utf8_general_ci',
        'init-connect'                   => 'SET NAMES utf8',
        'character-set-server'           => 'utf8',
        'skip-name-resolve'              => $mysql_skip_name_resolve,
        'performance_schema'             => $mysql_performance_schema,
        'myisam_sort_buffer_size'        => '64M',
        'wait_timeout'                   => '1800',
        'open_files_limit'               => '102400',
        'table_open_cache'               => '10000',
        'key_buffer_size'                => $key_buffer_size,
        'max_allowed_packet'             => '256M',
        'query_cache_size'               => '0',
        'query_cache_type'               => '0',
        'innodb_file_format'             => 'Barracuda',
        'innodb_file_per_table'          => '1',
        'innodb_buffer_pool_size'        => "${innodb_buffer_pool_size}M",
        'innodb_log_file_size'           => "${innodb_log_file_size}M",
        'innodb_read_io_threads'         => '8',
        'innodb_write_io_threads'        => '8',
        'innodb_io_capacity'             => '500',
        'innodb_flush_log_at_trx_commit' => '2',
        'innodb_flush_method'            => 'O_DIRECT',
        'innodb_doublewrite'             => '0',
      },
    }

    $server_list = join($galera_nodes, ',')
    $wsrep_options = {
      'mysqld'                           => {
        'binlog_format'                  => 'ROW',
        'default-storage-engine'         => 'innodb',
        'innodb_autoinc_lock_mode'       => '2',
        'innodb_locks_unsafe_for_binlog' => '1',
        'query_cache_size'               => '0',
        'query_cache_type'               => '0',
        'wsrep_cluster_address'          => "\"gcomm://${server_list}\"",
        'wsrep_cluster_name'             => $galera_cluster_name,
        'wsrep_provider_options'         => $wsrep_provider_options,
        'wsrep_slave_threads'            => $wsrep_slave_threads,
        'wsrep_sst_method'               => 'xtrabackup-v2',
        'wsrep_sst_auth'                 => "\"root:${mysql_database_password}\"", #TODO fix this, should be a specific user not root
        'wsrep_node_address'             => $galera_node_address,
        'wsrep_node_incoming_address'    => $galera_node_address,
        'wsrep_sst_receive_address'      => $galera_node_address,
      },
      'xtrabackup' => {
        'parallel' => inline_template("<%= [[${::processorcount}, 2].max, 6].min %>"),
      },
      'sst'        => {
        'streamfmt'   => 'xbstream',
        'transferfmt' => 'socat',
        'sockopts'    => 'nodelay,sndbuff=1048576,rcvbuf=1048576',
      }

    }

    tweaks::ubuntu_service_override { 'mysql':
      package_name => $mysql_package_name,
    }

    # build our mysql options to be configured in my.cnf
    $mysql_override_options = mysql_deepmerge(
      $fuel_override_options,
      $ignore_db_dir_options,
      $binary_logs_options,
      $syslog_options
    )
    $galera_options = mysql_deepmerge($wsrep_options, $vendor_override_options)
    $override_options = mysql_deepmerge($mysql_override_options, $galera_options)

    class { '::galera':
      vendor_type           => $vendor_type,
      mysql_package_name    => $mysql_package_name,
      galera_package_name   => $galera_package_name,
      client_package_name   => $client_package_name,
      galera_servers        => $galera_nodes,
      galera_master         => false, # NOTE: we don't want the galera module to boostrap
      mysql_port            => $backend_port,
      root_password         => $mysql_database_password,
      create_root_user      => $primary_controller,
      create_root_my_cnf    => true,
      configure_repo        => false, # NOTE: repos should be managed via fuel
      configure_firewall    => false,
      validate_connection   => false,
      status_check          => false,
      wsrep_group_comm_port => $wsrep_group_comm_port,
      bind_address          => $galera_node_address,
      local_ip              => $galera_node_address,
      wsrep_sst_method      => 'xtrabackup-v2',
      override_options      => $override_options,
    }

    # Make sure the mysql service is stopped with upstart as we will be starting
    # it with pacemaker
    Exec <| title == 'clean_up_ubuntu' |> {
      command => 'service mysql stop || true'
    }

    $wsrep_config_file = '/etc/mysql/conf.d/wsrep.cnf'
    # Remove the wsrep config that comes from the packages as we put everything
    # in /etc/mysql/my.cnf
    file { $wsrep_config_file:
      ensure => absent,
      before => Class['::mysql::server::installdb'],
    }

    $management_networks = get_routable_networks_for_network_role($network_scheme, 'mgmt/database', ' ')
    # TODO(aschultz): switch to ::galera::status
    class { '::openstack::galera::status':
      status_user     => $status_user,
      status_password => $status_password,
      status_allow    => $galera_node_address,
      backend_host    => $galera_node_address,
      backend_port    => $backend_port,
      backend_timeout => $backend_timeout,
      only_from       => "127.0.0.1 240.0.0.2 ${management_networks}",
    }

    # include our integration with pacemaker
    class { '::cluster::mysql':
      mysql_user     => $status_user,
      mysql_password => $status_password,
      mysql_config   => '/etc/mysql/my.cnf',
      mysql_socket   => $mysql_socket,
    }

    $lb_defaults = { 'provider' => 'haproxy', 'url' => $haproxy_stats_url }

    if $external_lb {
      $lb_backend_provider = 'http'
      $lb_url = "http://${database_vip}:49000"
    }

    $lb_hash = {
      mysql      => {
        name     => 'mysqld',
        provider => $lb_backend_provider,
        url      => $lb_url
      }
    }

    ::osnailyfacter::wait_for_backend {'mysql':
      lb_hash     => $lb_hash,
      lb_defaults => $lb_defaults
    }

    # this overrides /root/.my.cnf created by mysql::server::root_password
    # TODO: (sgolovatiuk): This class should be removed once
    # https://github.com/puppetlabs/puppetlabs-mysql/pull/801/files is accepted
    class { '::osnailyfacter::mysql_access':
      db_password => $mysql_database_password,
    }

    # this sets up remote grants for use with detached db
    class { '::osnailyfacter::mysql_user_access':
      db_user          => 'root',
      db_password_hash => mysql_password($mysql_database_password),
      access_networks  => $access_networks,
    }

    Class['::galera'] ->
      Class['::osnailyfacter::mysql_access'] ->
        Class['::osnailyfacter::mysql_user_access']

    Class['::openstack::galera::status'] ->
      ::Osnailyfacter::Wait_for_backend['mysql']
  }

}
