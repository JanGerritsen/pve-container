package PVE::LXC;

use strict;
use warnings;
use POSIX qw(EINTR);

use File::Path;
use Fcntl ':flock';

use PVE::Cluster qw(cfs_register_file cfs_read_file);
use PVE::Storage;
use PVE::SafeSyslog;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw($IPV6RE $IPV4RE);
use PVE::Network;

use Data::Dumper;

cfs_register_file('/lxc/', \&parse_lxc_config, \&write_lxc_config);

PVE::JSONSchema::register_format('pve-lxc-network', \&verify_lxc_network);
sub verify_lxc_network {
    my ($value, $noerr) = @_;

    return $value if parse_lxc_network($value);

    return undef if $noerr;

    die "unable to parse network setting\n";
}

my $nodename = PVE::INotify::nodename();

sub parse_lxc_size {
    my ($name, $value) = @_;

    if ($value =~ m/^(\d+)(b|k|m|g)?$/i) {
	my ($res, $unit) = ($1, lc($2 || 'b'));

	return $res if $unit eq 'b';
	return $res*1024 if $unit eq 'k';
	return $res*1024*1024 if $unit eq 'm';
	return $res*1024*1024*1024 if $unit eq 'g';
    }

    return undef;
}

my $valid_lxc_keys = {
    'lxc.arch' => 'i386|x86|i686|x86_64|amd64',
    'lxc.include' => 1,
    'lxc.rootfs' => 1,
    'lxc.mount' => 1,
    'lxc.utsname' => 1,

    'lxc.id_map' => 1,

    'lxc.cgroup.memory.limit_in_bytes' => \&parse_lxc_size,
    'lxc.cgroup.memory.memsw.limit_in_bytes' => \&parse_lxc_size,
    'lxc.cgroup.cpu.cfs_period_us' => '\d+',
    'lxc.cgroup.cpu.cfs_quota_us' => '\d+',
    'lxc.cgroup.cpu.shares' => '\d+',

    # mount related
    'lxc.mount' => 1,
    'lxc.mount.entry' => 1,
    'lxc.mount.auto' => 1,

    # not used by pve
    'lxc.tty' => '\d+',
    'lxc.pts' => 1,
    'lxc.haltsignal' => 1,
    'lxc.rebootsignal' => 1,
    'lxc.stopsignal' => 1,
    'lxc.init_cmd' => 1,
    'lxc.console' => 1,
    'lxc.console.logfile' => 1,
    'lxc.devttydir' => 1,
    'lxc.autodev' => 1,
    'lxc.kmsg' => 1,
    'lxc.cap.drop' => 1,
    'lxc.cap.keep' => 1,
    'lxc.aa_profile' => 1,
    'lxc.aa_allow_incomplete' => 1,
    'lxc.se_context' => 1,
    'lxc.loglevel' => 1,
    'lxc.logfile' => 1,
    'lxc.environment' => 1,
    'lxc.cgroup.devices.deny' => 1,

    # autostart
    'lxc.start.auto' => 1,
    'lxc.start.delay' => 1,
    'lxc.start.order' => 1,
    'lxc.group' => 1,

    # hooks
    'lxc.hook.pre-start' => 1,
    'lxc.hook.pre-mount' => 1,
    'lxc.hook.mount' => 1,
    'lxc.hook.autodev' => 1,
    'lxc.hook.start' => 1,
    'lxc.hook.post-stop' => 1,
    'lxc.hook.clone' => 1,

    # pve related keys
    'pve.nameserver' => sub {
	my ($name, $value) = @_;
	return verify_nameserver_list($value);
    },
    'pve.searchdomain' => sub {
	my ($name, $value) = @_;
	return verify_searchdomain_list($value);
    },
    'pve.onboot' => '(0|1)',
    'pve.startup' => sub {
	my ($name, $value) = @_;
	return PVE::JSONSchema::pve_verify_startup_order($value);
    },
    'pve.comment' => 1,
    'pve.disksize' => '\d+(\.\d+)?',
    'pve.volid' => sub {
	my ($name, $value) = @_;
	PVE::Storage::parse_volume_id($value);
	return $value;
    },

     #pve snapshot
    'pve.lock' => 1,
    'pve.snaptime' => 1,
    'pve.snapcomment' => 1,
    'pve.parent' => 1,
    'pve.snapstate' => 1,
    'pve.snapname' => 1,
};

my $valid_lxc_network_keys = {
    type => 1,
    mtu => 1,
    name => 1, # ifname inside container
    'veth.pair' => 1, # ifname at host (eth${vmid}.X)
    hwaddr => 1,
};

my $valid_pve_network_keys = {
    bridge => 1,
    tag => 1,
    firewall => 1,
    ip => 1,
    gw => 1,
    ip6 => 1,
    gw6 => 1,
};

my $lxc_array_configs = {
    'lxc.network' => 1,
    'lxc.mount' => 1,
    'lxc.include' => 1,
    'lxc.id_map' => 1,
    'lxc.cgroup.devices.deny' => 1,
};

sub write_lxc_config {
    my ($filename, $data) = @_;

    my $raw = "";

    return $raw if !$data;

    my $dump_entry = sub {
	my ($k, $value, $done_hash, $snapshot) = @_;
	return if !defined($value);
	return if $done_hash->{$k};
	$done_hash->{$k} = 1;
	if (ref($value)) {
	    die "got unexpected reference for '$k'"
		if !$lxc_array_configs->{$k};
	    foreach my $v (@$value) {
		$raw .= 'snap.' if $snapshot;
		$raw .= "$k = $v\n";
	    }
	} else {
	    $raw .= 'snap.' if $snapshot;
	    $raw .= "$k = $value\n";
	}
    };

    my $config_writer = sub {
	my ($elem, $snapshot) = @_;

	my $done_hash = { digest => 1};

	if (defined(my $value = $elem->{'pve.snapname'})) {
	     &$dump_entry('pve.snapname', $value, $done_hash, $snapshot);
	}

	# Note: Order is important! Include defaults first, so that we
	# can overwrite them later.
	&$dump_entry('lxc.include', $elem->{'lxc.include'}, $done_hash, $snapshot);

	foreach my $k (sort keys %$elem) {
	    next if $k !~ m/^lxc\./;
	    &$dump_entry($k, $elem->{$k}, $done_hash, $snapshot);
	}
	foreach my $k (sort keys %$elem) {
	    next if $k !~ m/^pve\./;
	    &$dump_entry($k, $elem->{$k}, $done_hash, $snapshot);
	}
	my $network_count = 0;

	foreach my $k (sort keys %$elem) {
	    next if $k !~ m/^net\d+$/;
	    $done_hash->{$k} = 1;

	    my $net = $elem->{$k};
	    $network_count++;
	    $raw .= 'snap.' if $snapshot;
	    $raw .= "lxc.network.type = $net->{type}\n";
	    foreach my $subkey (sort keys %$net) {
		next if $subkey eq 'type';
		if ($valid_lxc_network_keys->{$subkey}) {
		    $raw .= 'snap.' if $snapshot;
		    $raw .= "lxc.network.$subkey = $net->{$subkey}\n";
		} elsif ($valid_pve_network_keys->{$subkey}) {
		    $raw .= 'snap.' if $snapshot;
		    $raw .= "pve.network.$subkey = $net->{$subkey}\n";
		} else {
		    die "found invalid network key '$subkey'";
		}
	    }
	}
	if (!$network_count) {
	    $raw .= 'snap.' if $snapshot;
	    $raw .= "lxc.network.type = empty\n";
	}
	foreach my $k (sort keys %$elem) {
	    next if $k eq 'snapshots';
	    next if $done_hash->{$k};
	    die "found un-written value \"$k\" in config - implement this!";
	}

    };

    &$config_writer($data);

    if ($data->{snapshots}) {
	my @tmp = sort { $data->{snapshots}->{$b}{'pve.snaptime'} <=>
			      $data->{snapshots}->{$a}{'pve.snaptime'} }
			keys %{$data->{snapshots}};
	foreach my $snapname (@tmp) {
	    $raw .= "\n";
	    &$config_writer($data->{snapshots}->{$snapname}, 1);
	}
    }

    return $raw;
}

sub parse_lxc_option {
    my ($name, $value) = @_;

    my $parser = $valid_lxc_keys->{$name};

    die "invalid key '$name'\n" if !defined($parser);

    if ($parser eq '1') {
	return $value;
    } elsif (ref($parser)) {
	my $res = &$parser($name, $value);
	return $res if defined($res);
    } else {
	# assume regex
	return $value if $value =~ m/^$parser$/;
    }

    die "unable to parse value '$value' for option '$name'\n";
}

sub parse_lxc_config {
    my ($filename, $raw) = @_;

    return undef if !defined($raw);

    my $data = {
	digest => Digest::SHA::sha1_hex($raw),
    };

    $filename =~ m|/lxc/(\d+)/config$|
	|| die "got strange filename '$filename'";

    my $vmid = $1;

    my $split_config = sub {
	my ($raw) = @_;
	my $sections = [];
	my $tmp = '';
	while ($raw && $raw =~ s/^(.*)?(\n|$)//) {
	    my $line = $1;
	    if(!$line) {
		push(@{$sections},$tmp);
		$tmp = '';
	    } else {
		$tmp .= "$line\n";
	    }
	}
	push(@{$sections},$tmp);

	return $sections;
    };

    my $sec = &$split_config($raw);

    foreach my  $sec_raw (@{$sec}){
	next if $sec_raw eq '';
	my $snapname = undef;

	my $network_counter = 0;
	my $network_list = [];
	my $host_ifnames = {};

	my $find_next_hostif_name = sub {
	    for (my $i = 0; $i < 10; $i++) {
		my $name = "veth${vmid}.$i";
		if (!$host_ifnames->{$name}) {
		    $host_ifnames->{$name} = 1;
		    return $name;
		}
	    }

	    die "unable to find free host_ifname"; # should not happen
	};

	my $push_network = sub {
	    my ($netconf) = @_;
	    return if !$netconf;
	    push @{$network_list}, $netconf;
	    $network_counter++;
	    if (my $netname = $netconf->{'veth.pair'}) {
		if ($netname =~ m/^veth(\d+).(\d)$/) {
		    die "wrong vmid for network interface pair\n" if $1 != $vmid;
		    my $host_ifnames->{$netname} = 1;
		} else {
		    die "wrong network interface pair\n";
		}
	    }
	};

	my $network;

	while ($sec_raw && $sec_raw =~ s/^(.*?)(\n|$)//) {
	    my $line = $1;

	    next if $line =~ m/^\#/;
	    next if $line =~ m/^\s*$/;

	    if ($line =~ m/^(snap\.)?lxc\.network\.(\S+)\s*=\s*(\S+)\s*$/) {
		my ($subkey, $value) = ($2, $3);
		if ($subkey eq 'type') {
		    &$push_network($network);
		    $network = { type => $value };
		} elsif ($valid_lxc_network_keys->{$subkey}) {
		    $network->{$subkey} = $value;
		} else {
		    die "unable to parse config line: $line\n";
		}
		next;
	    }
	    if ($line =~ m/^(snap\.)?pve\.network\.(\S+)\s*=\s*(\S+)\s*$/) {
		my ($subkey, $value) = ($2, $3);
		if ($valid_pve_network_keys->{$subkey}) {
		    $network->{$subkey} = $value;
		} else {
		    die "unable to parse config line: $line\n";
		}
		next;
	    }
	    if ($line =~ m/^(snap\.)?(pve.snapcomment)\s*=\s*(\S.*)\s*$/) {
		my ($name, $value) = ($2, $3);
		if ($snapname) {
		    $data->{snapshots}->{$snapname}->{$name} = $value;
		}
		next;
	    }
	    if ($line =~ m/^(snap\.)?pve\.snapname = (\w*)$/) {
		if (!$snapname) {
		    $snapname = $2;
		    $data->{snapshots}->{$snapname}->{'pve.snapname'} = $snapname;
		} else {
		    die "Configuarion broken\n";
		}
		next;
	    }
	    if ($line =~ m/^(snap\.)?((?:pve|lxc)\.\S+)\s*=\s*(\S.*)\s*$/) {
		my ($name, $value) = ($2, $3);

		if ($lxc_array_configs->{$name}) {
		    $data->{$name} = [] if !defined($data->{$name});
		    if ($snapname) {
			push @{$data->{snapshots}->{$snapname}->{$name}},  parse_lxc_option($name, $value);
		    } else {
			push @{$data->{$name}},  parse_lxc_option($name, $value);
		    }
		} else {
		    if ($snapname) {
			die "multiple definitions for $name\n" if defined($data->{snapshots}->{$snapname}->{$name});
			$data->{snapshots}->{$snapname}->{$name} = parse_lxc_option($name, $value);
		    } else {
			die "multiple definitions for $name\n" if defined($data->{$name});
			$data->{$name} = parse_lxc_option($name, $value);
		    }
		}

		next;
	    }
	    die "unable to parse config line: $line\n";
	}
	&$push_network($network);

	foreach my $net (@{$network_list}) {
	    next if $net->{type} eq 'empty'; # skip
	    $net->{'veth.pair'} = &$find_next_hostif_name() if !$net->{'veth.pair'};
	    $net->{hwaddr} =  PVE::Tools::random_ether_addr() if !$net->{hwaddr};
	    die "unsupported network type '$net->{type}'\n" if $net->{type} ne 'veth';

	    if ($net->{'veth.pair'} =~ m/^veth\d+.(\d+)$/) {
		if ($snapname) {
		    $data->{snapshots}->{$snapname}->{"net$1"} = $net;
		} else {
		    $data->{"net$1"} = $net;
		}
	    }
	}
    }

    return $data;
}

sub config_list {
    my $vmlist = PVE::Cluster::get_vmlist();
    my $res = {};
    return $res if !$vmlist || !$vmlist->{ids};
    my $ids = $vmlist->{ids};

    foreach my $vmid (keys %$ids) {
	next if !$vmid; # skip CT0
	my $d = $ids->{$vmid};
	next if !$d->{node} || $d->{node} ne $nodename;
	next if !$d->{type} || $d->{type} ne 'lxc';
	$res->{$vmid}->{type} = 'lxc';
    }
    return $res;
}

sub cfs_config_path {
    my ($vmid, $node) = @_;

    $node = $nodename if !$node;
    return "nodes/$node/lxc/$vmid/config";
}

sub config_file {
    my ($vmid, $node) = @_;

    my $cfspath = cfs_config_path($vmid, $node);
    return "/etc/pve/$cfspath";
}

sub load_config {
    my ($vmid) = @_;

    my $cfspath = cfs_config_path($vmid);

    my $conf = PVE::Cluster::cfs_read_file($cfspath);
    die "container $vmid does not exists\n" if !defined($conf);

    return $conf;
}

sub create_config {
    my ($vmid, $conf) = @_;

    my $dir = "/etc/pve/nodes/$nodename/lxc";
    mkdir $dir;

    $dir .= "/$vmid";
    mkdir($dir) || die "unable to create container configuration directory - $!\n";

    write_config($vmid, $conf);
}

sub destroy_config {
    my ($vmid) = @_;

    my $dir = "/etc/pve/nodes/$nodename/lxc/$vmid";
    File::Path::rmtree($dir);
}

sub write_config {
    my ($vmid, $conf) = @_;

    my $cfspath = cfs_config_path($vmid);

    PVE::Cluster::cfs_write_file($cfspath, $conf);
}

my $tempcounter = 0;
sub write_temp_config {
    my ($vmid, $conf) = @_;

    $tempcounter++;
    my $filename = "/tmp/temp-lxc-conf-$vmid-$$-$tempcounter.conf";

    my $raw =  write_lxc_config($filename, $conf);

    PVE::Tools::file_set_contents($filename, $raw);

    return $filename;
}

# flock: we use one file handle per process, so lock file
# can be called multiple times and succeeds for the same process.

my $lock_handles =  {};
my $lockdir = "/run/lock/lxc";

sub lock_filename {
    my ($vmid) = @_;

    return "$lockdir/pve-config-{$vmid}.lock";
}

sub lock_aquire {
    my ($vmid, $timeout) = @_;

    $timeout = 10 if !$timeout;
    my $mode = LOCK_EX;

    my $filename = lock_filename($vmid);

    mkdir $lockdir if !-d $lockdir;

    my $lock_func = sub {
	if (!$lock_handles->{$$}->{$filename}) {
	    my $fh = new IO::File(">>$filename") ||
		die "can't open file - $!\n";
	    $lock_handles->{$$}->{$filename} = { fh => $fh, refcount => 0};
	}

	if (!flock($lock_handles->{$$}->{$filename}->{fh}, $mode |LOCK_NB)) {
	    print STDERR "trying to aquire lock...";
	    my $success;
	    while(1) {
		$success = flock($lock_handles->{$$}->{$filename}->{fh}, $mode);
		# try again on EINTR (see bug #273)
		if ($success || ($! != EINTR)) {
		    last;
		}
	    }
	    if (!$success) {
		print STDERR " failed\n";
		die "can't aquire lock - $!\n";
	    }

	    $lock_handles->{$$}->{$filename}->{refcount}++;

	    print STDERR " OK\n";
	}
    };

    eval { PVE::Tools::run_with_timeout($timeout, $lock_func); };
    my $err = $@;
    if ($err) {
	die "can't lock file '$filename' - $err";
    }
}

sub lock_release {
    my ($vmid) = @_;

    my $filename = lock_filename($vmid);

    if (my $fh = $lock_handles->{$$}->{$filename}->{fh}) {
	my $refcount = --$lock_handles->{$$}->{$filename}->{refcount};
	if ($refcount <= 0) {
	    $lock_handles->{$$}->{$filename} = undef;
	    close ($fh);
	}
    }
}

sub lock_container {
    my ($vmid, $timeout, $code, @param) = @_;

    my $res;

    lock_aquire($vmid, $timeout);
    eval { $res = &$code(@param) };
    my $err = $@;
    lock_release($vmid);

    die $err if $err;

    return $res;
}

my $confdesc = {
    onboot => {
	optional => 1,
	type => 'boolean',
	description => "Specifies whether a VM will be started during system bootup.",
	default => 0,
    },
    startup => get_standard_option('pve-startup-order'),
    cpulimit => {
	optional => 1,
	type => 'number',
	description => "Limit of CPU usage. Note if the computer has 2 CPUs, it has total of '2' CPU time. Value '0' indicates no CPU limit.",
	minimum => 0,
	maximum => 128,
	default => 0,
    },
    cpuunits => {
	optional => 1,
	type => 'integer',
	description => "CPU weight for a VM. Argument is used in the kernel fair scheduler. The larger the number is, the more CPU time this VM gets. Number is relative to weights of all the other running VMs.\n\nNOTE: You can disable fair-scheduler configuration by setting this to 0.",
	minimum => 0,
	maximum => 500000,
	default => 1000,
    },
    memory => {
	optional => 1,
	type => 'integer',
	description => "Amount of RAM for the VM in MB.",
	minimum => 16,
	default => 512,
    },
    swap => {
	optional => 1,
	type => 'integer',
	description => "Amount of SWAP for the VM in MB.",
	minimum => 0,
	default => 512,
    },
    disk => {
	optional => 1,
	type => 'number',
	description => "Amount of disk space for the VM in GB. A zero indicates no limits.",
	minimum => 0,
	default => 4,
    },
    hostname => {
	optional => 1,
	description => "Set a host name for the container.",
	type => 'string',
	maxLength => 255,
    },
    description => {
	optional => 1,
	type => 'string',
	description => "Container description. Only used on the configuration web interface.",
    },
    searchdomain => {
	optional => 1,
	type => 'string',
	description => "Sets DNS search domains for a container. Create will automatically use the setting from the host if you neither set searchdomain or nameserver.",
    },
    nameserver => {
	optional => 1,
	type => 'string',
	description => "Sets DNS server IP address for a container. Create will automatically use the setting from the host if you neither set searchdomain or nameserver.",
    },
};

my $MAX_LXC_NETWORKS = 10;
for (my $i = 0; $i < $MAX_LXC_NETWORKS; $i++) {
    $confdesc->{"net$i"} = {
	optional => 1,
	type => 'string', format => 'pve-lxc-network',
	description => "Specifies network interfaces for the container.\n\n".
	    "The string should have the follow format:\n\n".
	    "-net<[0-9]> bridge=<vmbr<Nummber>>[,hwaddr=<MAC>]\n".
	    "[,mtu=<Number>][,name=<String>][,ip=<IPv4Format/CIDR>]\n".
	    ",ip6=<IPv6Format/CIDR>][,gw=<GatwayIPv4>]\n".
	    ",gw6=<GatwayIPv6>][,firewall=<[1|0]>][,tag=<VlanNo>]",
    };
}

sub option_exists {
    my ($name) = @_;

    return defined($confdesc->{$name});
}

# add JSON properties for create and set function
sub json_config_properties {
    my $prop = shift;

    foreach my $opt (keys %$confdesc) {
	$prop->{$opt} = $confdesc->{$opt};
    }

    return $prop;
}

# container status helpers

sub list_active_containers {

    my $filename = "/proc/net/unix";

    # similar test is used by lcxcontainers.c: list_active_containers
    my $res = {};

    my $fh = IO::File->new ($filename, "r");
    return $res if !$fh;

    while (defined(my $line = <$fh>)) {
 	if ($line =~ m/^[a-f0-9]+:\s\S+\s\S+\s\S+\s\S+\s\S+\s\d+\s(\S+)$/) {
	    my $path = $1;
	    if ($path =~ m!^@/etc/pve/lxc/(\d+)/command$!) {
		$res->{$1} = 1;
	    }
	}
    }

    close($fh);

    return $res;
}

# warning: this is slow
sub check_running {
    my ($vmid) = @_;

    my $active_hash = list_active_containers();

    return 1 if defined($active_hash->{$vmid});

    return undef;
}

sub get_container_disk_usage {
    my ($vmid) = @_;

    my $cmd = ['lxc-attach', '-n', $vmid, '--', 'df',  '-P', '-B', '1', '/'];

    my $res = {
	total => 0,
	used => 0,
	avail => 0,
    };

    my $parser = sub {
	my $line = shift;
	if (my ($fsid, $total, $used, $avail) = $line =~
	    m/^(\S+.*)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s.*$/) {
	    $res = {
		total => $total,
		used => $used,
		avail => $avail,
	    };
	}
    };
    eval { PVE::Tools::run_command($cmd, timeout => 1, outfunc => $parser); };
    warn $@ if $@;

    return $res;
}

sub vmstatus {
    my ($opt_vmid) = @_;

    my $list = $opt_vmid ? { $opt_vmid => { type => 'lxc' }} : config_list();

    my $active_hash = list_active_containers();

    foreach my $vmid (keys %$list) {
	my $d = $list->{$vmid};

	my $running = defined($active_hash->{$vmid});

	$d->{status} = $running ? 'running' : 'stopped';

	my $cfspath = cfs_config_path($vmid);
	my $conf = PVE::Cluster::cfs_read_file($cfspath) || {};

	$d->{name} = $conf->{'lxc.utsname'} || "CT$vmid";
	$d->{name} =~ s/[\s]//g;

	$d->{cpus} = 0;

	my $cfs_period_us = $conf->{'lxc.cgroup.cpu.cfs_period_us'};
	my $cfs_quota_us = $conf->{'lxc.cgroup.cpu.cfs_quota_us'};

	if ($cfs_period_us && $cfs_quota_us) {
	    $d->{cpus} = int($cfs_quota_us/$cfs_period_us);
	}

	$d->{disk} = 0;
	$d->{maxdisk} = defined($conf->{'pve.disksize'}) ?
	    int($conf->{'pve.disksize'}*1024*1024)*1024 : 1024*1024*1024*1024*1024;

	if (my $private = $conf->{'lxc.rootfs'}) {
	    if ($private =~ m!^/!) {
		my $res = PVE::Tools::df($private, 2);
		$d->{disk} = $res->{used};
		$d->{maxdisk} = $res->{total};
	    } elsif ($running) {
		if ($private =~ m!^(?:loop|nbd):(?:\S+)$!) {
		    my $res = get_container_disk_usage($vmid);
		    $d->{disk} = $res->{used};
		    $d->{maxdisk} = $res->{total};
		}
	    }
	}

	$d->{mem} = 0;
	$d->{swap} = 0;
	$d->{maxmem} = ($conf->{'lxc.cgroup.memory.limit_in_bytes'}||0) +
	    ($conf->{'lxc.cgroup.memory.memsw.limit_in_bytes'}||0);

	$d->{uptime} = 0;
	$d->{cpu} = 0;

	$d->{netout} = 0;
	$d->{netin} = 0;

	$d->{diskread} = 0;
	$d->{diskwrite} = 0;
    }

    foreach my $vmid (keys %$list) {
	my $d = $list->{$vmid};
	next if $d->{status} ne 'running';

	$d->{uptime} = 100; # fixme:

	$d->{mem} = read_cgroup_value('memory', $vmid, 'memory.usage_in_bytes');
	$d->{swap} = read_cgroup_value('memory', $vmid, 'memory.memsw.usage_in_bytes') - $d->{mem};

	my $blkio_bytes = read_cgroup_value('blkio', $vmid, 'blkio.throttle.io_service_bytes', 1);
	my @bytes = split(/\n/, $blkio_bytes);
	foreach my $byte (@bytes) {
	    if (my ($key, $value) = $byte =~ /(Read|Write)\s+(\d+)/) {
		$d->{diskread} = $2 if $key eq 'Read';
		$d->{diskwrite} = $2 if $key eq 'Write';
	    }
	}
    }

    return $list;
}


sub print_lxc_network {
    my $net = shift;

    die "no network name defined\n" if !$net->{name};

    my $res = "name=$net->{name}";

    foreach my $k (qw(hwaddr mtu bridge ip gw ip6 gw6 firewall tag)) {
	next if !defined($net->{$k});
	$res .= ",$k=$net->{$k}";
    }

    return $res;
}

sub parse_lxc_network {
    my ($data) = @_;

    my $res = {};

    return $res if !$data;

    foreach my $pv (split (/,/, $data)) {
	if ($pv =~ m/^(bridge|hwaddr|mtu|name|ip|ip6|gw|gw6|firewall|tag)=(\S+)$/) {
	    $res->{$1} = $2;
	} else {
	    return undef;
	}
    }

    $res->{type} = 'veth';
    $res->{hwaddr} = PVE::Tools::random_ether_addr() if !$res->{hwaddr};

    return $res;
}

sub read_cgroup_value {
    my ($group, $vmid, $name, $full) = @_;

    my $path = "/sys/fs/cgroup/$group/lxc/$vmid/$name";

    return PVE::Tools::file_get_contents($path) if $full;

    return PVE::Tools::file_read_firstline($path);
}

sub write_cgroup_value {
   my ($group, $vmid, $name, $value) = @_;

   my $path = "/sys/fs/cgroup/$group/lxc/$vmid/$name";
   PVE::ProcFSTools::write_proc_entry($path, $value) if -e $path;

}

sub find_lxc_console_pids {

    my $res = {};

    PVE::Tools::dir_glob_foreach('/proc', '\d+', sub {
	my ($pid) = @_;

	my $cmdline = PVE::Tools::file_read_firstline("/proc/$pid/cmdline");
	return if !$cmdline;

	my @args = split(/\0/, $cmdline);

	# serach for lxc-console -n <vmid>
	return if scalar(@args) != 3;
	return if $args[1] ne '-n';
	return if $args[2] !~ m/^\d+$/;
	return if $args[0] !~ m|^(/usr/bin/)?lxc-console$|;

	my $vmid = $args[2];

	push @{$res->{$vmid}}, $pid;
    });

    return $res;
}

sub find_lxc_pid {
    my ($vmid) = @_;

    my $pid = undef;
    my $parser = sub {
        my $line = shift;
        $pid = $1 if $line =~ m/^PID:\s+(\d+)$/;
    };
    PVE::Tools::run_command(['lxc-info', '-n', $vmid], outfunc => $parser);

    die "unable to get PID for CT $vmid (not running?)\n" if !$pid;

    return $pid;
}

my $ipv4_reverse_mask = [
    '0.0.0.0',
    '128.0.0.0',
    '192.0.0.0',
    '224.0.0.0',
    '240.0.0.0',
    '248.0.0.0',
    '252.0.0.0',
    '254.0.0.0',
    '255.0.0.0',
    '255.128.0.0',
    '255.192.0.0',
    '255.224.0.0',
    '255.240.0.0',
    '255.248.0.0',
    '255.252.0.0',
    '255.254.0.0',
    '255.255.0.0',
    '255.255.128.0',
    '255.255.192.0',
    '255.255.224.0',
    '255.255.240.0',
    '255.255.248.0',
    '255.255.252.0',
    '255.255.254.0',
    '255.255.255.0',
    '255.255.255.128',
    '255.255.255.192',
    '255.255.255.224',
    '255.255.255.240',
    '255.255.255.248',
    '255.255.255.252',
    '255.255.255.254',
    '255.255.255.255',
];

# Note: we cannot use Net:IP, because that only allows strict
# CIDR networks
sub parse_ipv4_cidr {
    my ($cidr, $noerr) = @_;

    if ($cidr =~ m!^($IPV4RE)(?:/(\d+))$! && ($2 > 7) &&  ($2 < 32)) {
	return { address => $1, netmask => $ipv4_reverse_mask->[$2] };
    }

    return undef if $noerr;

    die "unable to parse ipv4 address/mask\n";
}

sub check_lock {
    my ($conf) = @_;

    die "VM is locked ($conf->{'pve.lock'})\n" if $conf->{'pve.lock'};
}

sub lxc_conf_to_pve {
    my ($vmid, $lxc_conf) = @_;

    my $properties = json_config_properties();

    my $conf = { digest => $lxc_conf->{digest} };

    foreach my $k (keys %$properties) {

	if ($k eq 'description') {
	    if (my $raw = $lxc_conf->{'pve.comment'}) {
		$conf->{$k} = PVE::Tools::decode_text($raw);
	    }
	} elsif ($k eq 'onboot') {
	    $conf->{$k} = $lxc_conf->{'pve.onboot'} if  $lxc_conf->{'pve.onboot'};
	} elsif ($k eq 'startup') {
	    $conf->{$k} = $lxc_conf->{'pve.startup'} if  $lxc_conf->{'pve.startup'};
	} elsif ($k eq 'hostname') {
	    $conf->{$k} = $lxc_conf->{'lxc.utsname'} if $lxc_conf->{'lxc.utsname'};
	} elsif ($k eq 'nameserver') {
	    $conf->{$k} = $lxc_conf->{'pve.nameserver'} if $lxc_conf->{'pve.nameserver'};
	} elsif ($k eq 'searchdomain') {
	    $conf->{$k} = $lxc_conf->{'pve.searchdomain'} if $lxc_conf->{'pve.searchdomain'};
	} elsif ($k eq 'memory') {
	    if (my $value = $lxc_conf->{'lxc.cgroup.memory.limit_in_bytes'}) {
		$conf->{$k} = int($value / (1024*1024));
	    }
	} elsif ($k eq 'swap') {
	    if (my $value = $lxc_conf->{'lxc.cgroup.memory.memsw.limit_in_bytes'}) {
		my $mem = $lxc_conf->{'lxc.cgroup.memory.limit_in_bytes'} || 0;
		$conf->{$k} = int(($value -$mem) / (1024*1024));
	    }
	} elsif ($k eq 'cpulimit') {
	    my $cfs_period_us = $lxc_conf->{'lxc.cgroup.cpu.cfs_period_us'};
	    my $cfs_quota_us = $lxc_conf->{'lxc.cgroup.cpu.cfs_quota_us'};

	    if ($cfs_period_us && $cfs_quota_us) {
		$conf->{$k} = $cfs_quota_us/$cfs_period_us;
	    } else {
		$conf->{$k} = 0;
	    }
	} elsif ($k eq 'cpuunits') {
	    $conf->{$k} = $lxc_conf->{'lxc.cgroup.cpu.shares'} || 1024;
	} elsif ($k eq 'disk') {
	    $conf->{$k} = defined($lxc_conf->{'pve.disksize'}) ?
		$lxc_conf->{'pve.disksize'} : 0;
	} elsif ($k =~ m/^net\d$/) {
	    my $net = $lxc_conf->{$k};
	    next if !$net;
	    $conf->{$k} = print_lxc_network($net);
	}
    }

    if (my $parent = $lxc_conf->{'pve.parent'}) {
	    $conf->{parent} = $lxc_conf->{'pve.parent'};
    }

    if (my $parent = $lxc_conf->{'pve.snapcomment'}) {
	$conf->{description} = $lxc_conf->{'pve.snapcomment'};
    }

    if (my $parent = $lxc_conf->{'pve.snaptime'}) {
	$conf->{snaptime} = $lxc_conf->{'pve.snaptime'};
    }

    return $conf;
}

# verify and cleanup nameserver list (replace \0 with ' ')
sub verify_nameserver_list {
    my ($nameserver_list) = @_;

    my @list = ();
    foreach my $server (PVE::Tools::split_list($nameserver_list)) {
	PVE::JSONSchema::pve_verify_ip($server);
	push @list, $server;
    }

    return join(' ', @list);
}

sub verify_searchdomain_list {
    my ($searchdomain_list) = @_;

    my @list = ();
    foreach my $server (PVE::Tools::split_list($searchdomain_list)) {
	# todo: should we add checks for valid dns domains?
	push @list, $server;
    }

    return join(' ', @list);
}

sub update_lxc_config {
    my ($vmid, $conf, $running, $param, $delete) = @_;

    my @nohotplug;

    my $rootdir;
    if ($running) {
	my $pid = find_lxc_pid($vmid);
	$rootdir = "/proc/$pid/root";
    }

    if (defined($delete)) {
	foreach my $opt (@$delete) {
	    if ($opt eq 'hostname' || $opt eq 'memory') {
		die "unable to delete required option '$opt'\n";
	    } elsif ($opt eq 'swap') {
		delete $conf->{'lxc.cgroup.memory.memsw.limit_in_bytes'};
		write_cgroup_value("memory", $vmid, "memory.memsw.limit_in_bytes", -1);
	    } elsif ($opt eq 'description') {
		delete $conf->{'pve.comment'};
	    } elsif ($opt eq 'onboot') {
		delete $conf->{'pve.onboot'};
	    } elsif ($opt eq 'startup') {
		delete $conf->{'pve.startup'};
	    } elsif ($opt eq 'nameserver') {
		delete $conf->{'pve.nameserver'};
		push @nohotplug, $opt;
		next if $running;
	    } elsif ($opt eq 'searchdomain') {
		delete $conf->{'pve.searchdomain'};
		push @nohotplug, $opt;
		next if $running;
	    } elsif ($opt =~ m/^net(\d)$/) {
		delete $conf->{$opt};
		next if !$running;
		my $netid = $1;
		PVE::Network::veth_delete("veth${vmid}.$netid");
	    } else {
		die "implement me"
	    }
	    PVE::LXC::write_config($vmid, $conf) if $running;
	}
    }

    foreach my $opt (keys %$param) {
	my $value = $param->{$opt};
	if ($opt eq 'hostname') {
	    $conf->{'lxc.utsname'} = $value;
	} elsif ($opt eq 'onboot') {
	    $conf->{'pve.onboot'} = $value ? 1 : 0;
	} elsif ($opt eq 'startup') {
	    $conf->{'pve.startup'} = $value;
	} elsif ($opt eq 'nameserver') {
	    my $list = verify_nameserver_list($value);
	    $conf->{'pve.nameserver'} = $list;
	    push @nohotplug, $opt;
	    next if $running;
	} elsif ($opt eq 'searchdomain') {
	    my $list = verify_searchdomain_list($value);
	    $conf->{'pve.searchdomain'} = $list;
	    push @nohotplug, $opt;
	    next if $running;
	} elsif ($opt eq 'memory') {
	    $conf->{'lxc.cgroup.memory.limit_in_bytes'} = $value*1024*1024;
	    write_cgroup_value("memory", $vmid, "memory.limit_in_bytes", $value*1024*1024);
	} elsif ($opt eq 'swap') {
	    my $mem =  $conf->{'lxc.cgroup.memory.limit_in_bytes'};
	    $mem = $param->{memory}*1024*1024 if $param->{memory};
	    $conf->{'lxc.cgroup.memory.memsw.limit_in_bytes'} = $mem + $value*1024*1024;
	    write_cgroup_value("memory", $vmid, "memory.memsw.limit_in_bytes", $mem + $value*1024*1024);

	} elsif ($opt eq 'cpulimit') {
	    if ($value > 0) {
		my $cfs_period_us = 100000;
		$conf->{'lxc.cgroup.cpu.cfs_period_us'} = $cfs_period_us;
		$conf->{'lxc.cgroup.cpu.cfs_quota_us'} = $cfs_period_us*$value;
		write_cgroup_value("cpu", $vmid, "cpu.cfs_quota_us", $cfs_period_us*$value);
	    } else {
		delete $conf->{'lxc.cgroup.cpu.cfs_period_us'};
		delete $conf->{'lxc.cgroup.cpu.cfs_quota_us'};
		write_cgroup_value("cpu", $vmid, "cpu.cfs_quota_us", -1);
	    }
	} elsif ($opt eq 'cpuunits') {
	    $conf->{'lxc.cgroup.cpu.shares'} = $value;
	    write_cgroup_value("cpu", $vmid, "cpu.shares", $value);
	} elsif ($opt eq 'description') {
	    $conf->{'pve.comment'} = PVE::Tools::encode_text($value);
	} elsif ($opt eq 'disk') {
	    $conf->{'pve.disksize'} = $value;
	    push @nohotplug, $opt;
	    next if $running;
	} elsif ($opt =~ m/^net(\d+)$/) {
	    my $netid = $1;
	    my $net = PVE::LXC::parse_lxc_network($value);
	    $net->{'veth.pair'} = "veth${vmid}.$netid";
 	    if (!$running) {
		$conf->{$opt} = $net;
	    } else {
		update_net($vmid, $conf, $opt, $net, $netid, $rootdir);
	    }
	} else {
	    die "implement me: $opt";
	}
	PVE::LXC::write_config($vmid, $conf) if $running;
    }

    if ($running && scalar(@nohotplug)) {
	die "unable to modify " . join(',', @nohotplug) . " while container is running\n";
    }
}

sub get_primary_ips {
    my ($conf) = @_;

    # return data from net0

    my $net = $conf->{net0};
    return undef if !$net;

    my $ipv4 = $net->{ip};
    $ipv4 =~ s!/\d+$!! if $ipv4;
    my $ipv6 = $net->{ip};
    $ipv6 =~ s!/\d+$!! if $ipv6;

    return ($ipv4, $ipv6);
}

sub destory_lxc_container {
    my ($storage_cfg, $vmid, $conf) = @_;

    if (my $volid = $conf->{'pve.volid'}) {

	my ($vtype, $name, $owner) = PVE::Storage::parse_volname($storage_cfg, $volid);
	die "got strange volid (containe is not owner!)\n" if $vmid != $owner;

	PVE::Storage::vdisk_free($storage_cfg, $volid);

	destroy_config($vmid);

    } else {
	my $cmd = ['lxc-destroy', '-n', $vmid ];

	PVE::Tools::run_command($cmd);
    }
}

my $safe_num_ne = sub {
    my ($a, $b) = @_;

    return 0 if !defined($a) && !defined($b);
    return 1 if !defined($a);
    return 1 if !defined($b);

    return $a != $b;
};

my $safe_string_ne = sub {
    my ($a, $b) = @_;

    return 0 if !defined($a) && !defined($b);
    return 1 if !defined($a);
    return 1 if !defined($b);

    return $a ne $b;
};

sub update_net {
    my ($vmid, $conf, $opt, $newnet, $netid, $rootdir) = @_;

    my $veth = $newnet->{'veth.pair'};
    my $vethpeer = $veth . "p";
    my $eth = $newnet->{name};

    if ($conf->{$opt}) {
	if (&$safe_string_ne($conf->{$opt}->{hwaddr}, $newnet->{hwaddr}) ||
	    &$safe_string_ne($conf->{$opt}->{name}, $newnet->{name})) {

            PVE::Network::veth_delete($veth);
	    delete $conf->{$opt};
	    PVE::LXC::write_config($vmid, $conf);

	    hotplug_net($vmid, $conf, $opt, $newnet);

	} elsif (&$safe_string_ne($conf->{$opt}->{bridge}, $newnet->{bridge}) ||
                &$safe_num_ne($conf->{$opt}->{tag}, $newnet->{tag}) ||
                &$safe_num_ne($conf->{$opt}->{firewall}, $newnet->{firewall})) {

		if ($conf->{$opt}->{bridge}){
		    PVE::Network::tap_unplug($veth);
		    delete $conf->{$opt}->{bridge};
		    delete $conf->{$opt}->{tag};
		    delete $conf->{$opt}->{firewall};
		    PVE::LXC::write_config($vmid, $conf);
		}

                PVE::Network::tap_plug($veth, $newnet->{bridge}, $newnet->{tag}, $newnet->{firewall});
		$conf->{$opt}->{bridge} = $newnet->{bridge} if $newnet->{bridge};
		$conf->{$opt}->{tag} = $newnet->{tag} if $newnet->{tag};
		$conf->{$opt}->{firewall} = $newnet->{firewall} if $newnet->{firewall};
		PVE::LXC::write_config($vmid, $conf);
	}
    } else {
	hotplug_net($vmid, $conf, $opt, $newnet);
    }

    update_ipconfig($vmid, $conf, $opt, $eth, $newnet, $rootdir);
}

sub hotplug_net {
    my ($vmid, $conf, $opt, $newnet) = @_;

    my $veth = $newnet->{'veth.pair'};
    my $vethpeer = $veth . "p";
    my $eth = $newnet->{name};

    PVE::Network::veth_create($veth, $vethpeer, $newnet->{bridge}, $newnet->{hwaddr});
    PVE::Network::tap_plug($veth, $newnet->{bridge}, $newnet->{tag}, $newnet->{firewall});

    # attach peer in container
    my $cmd = ['lxc-device', '-n', $vmid, 'add', $vethpeer, "$eth" ];
    PVE::Tools::run_command($cmd);

    # link up peer in container
    $cmd = ['lxc-attach', '-n', $vmid, '-s', 'NETWORK', '--', '/sbin/ip', 'link', 'set', $eth ,'up'  ];
    PVE::Tools::run_command($cmd);

    $conf->{$opt}->{type} = 'veth';
    $conf->{$opt}->{bridge} = $newnet->{bridge} if $newnet->{bridge};
    $conf->{$opt}->{tag} = $newnet->{tag} if $newnet->{tag};
    $conf->{$opt}->{firewall} = $newnet->{firewall} if $newnet->{firewall};
    $conf->{$opt}->{hwaddr} = $newnet->{hwaddr} if $newnet->{hwaddr};
    $conf->{$opt}->{name} = $newnet->{name} if $newnet->{name};
    $conf->{$opt}->{'veth.pair'} = $newnet->{'veth.pair'} if $newnet->{'veth.pair'};

    delete $conf->{$opt}->{ip} if $conf->{$opt}->{ip};
    delete $conf->{$opt}->{ip6} if $conf->{$opt}->{ip6};
    delete $conf->{$opt}->{gw} if $conf->{$opt}->{gw};
    delete $conf->{$opt}->{gw6} if $conf->{$opt}->{gw6};

    PVE::LXC::write_config($vmid, $conf);
}

sub update_ipconfig {
    my ($vmid, $conf, $opt, $eth, $newnet, $rootdir) = @_;

    my $lxc_setup = PVE::LXCSetup->new($conf, $rootdir);

    my $optdata = $conf->{$opt};
    my $deleted = [];
    my $added = [];
    my $netcmd = sub {
	my $cmd = ['lxc-attach', '-n', $vmid, '-s', 'NETWORK', '--', '/sbin/ip', @_];
	PVE::Tools::run_command($cmd);
    };

    my $change_ip_config = sub {
	my ($ipversion) = @_;

	my $family_opt = "-$ipversion";
	my $suffix = $ipversion == 4 ? '' : $ipversion;
	my $gw= "gw$suffix";
	my $ip= "ip$suffix";

	my $change_ip = &$safe_string_ne($optdata->{$ip}, $newnet->{$ip});
	my $change_gw = &$safe_string_ne($optdata->{$gw}, $newnet->{$gw});

	return if !$change_ip && !$change_gw;

	# step 1: add new IP, if this fails we cancel
	if ($change_ip && $newnet->{$ip}) {
	    eval { &$netcmd($family_opt, 'addr', 'add', $newnet->{$ip}, 'dev', $eth); };
	    if (my $err = $@) {
		warn $err;
		return;
	    }
	}

	# step 2: replace gateway
	#   If this fails we delete the added IP and cancel.
	#   If it succeeds we save the config and delete the old IP, ignoring
	#   errors. The config is then saved.
	# Note: 'ip route replace' can add
	if ($change_gw) {
	    if ($newnet->{$gw}) {
		eval { &$netcmd($family_opt, 'route', 'replace', 'default', 'via', $newnet->{$gw}); };
		if (my $err = $@) {
		    warn $err;
		    # the route was not replaced, the old IP is still available
		    # rollback (delete new IP) and cancel
		    if ($change_ip) {
			eval { &$netcmd($family_opt, 'addr', 'del', $newnet->{$ip}, 'dev', $eth); };
			warn $@ if $@; # no need to die here
		    }
		    return;
		}
	    } else {
		eval { &$netcmd($family_opt, 'route', 'del', 'default'); };
		# if the route was not deleted, the guest might have deleted it manually
		# warn and continue
		warn $@ if $@;
	    }
	}

	# from this point on we safe the configuration
	# step 3: delete old IP ignoring errors
	if ($change_ip && $optdata->{$ip}) {
	    eval { &$netcmd($family_opt, 'addr', 'del', $optdata->{$ip}, 'dev', $eth); };
	    warn $@ if $@; # no need to die here
	}

	foreach my $property ($ip, $gw) {
	    if ($newnet->{$property}) {
		$optdata->{$property} = $newnet->{$property};
	    } else {
		delete $optdata->{$property};
	    }
	}
	PVE::LXC::write_config($vmid, $conf);
	$lxc_setup->setup_network($conf);
    };

    &$change_ip_config(4);
    &$change_ip_config(6);

}

# Internal snapshots

# NOTE: Snapshot create/delete involves several non-atomic
# action, and can take a long time.
# So we try to avoid locking the file and use 'lock' variable
# inside the config file instead.

my $snapshot_copy_config = sub {
    my ($source, $dest) = @_;

    foreach my $k (keys %$source) {
	next if $k eq 'snapshots';
	next if $k eq 'pve.snapstate';
	next if $k eq 'pve.snaptime';
	next if $k eq 'pve.lock';
	next if $k eq 'digest';
	next if $k eq 'pve.comment';

	$dest->{$k} = $source->{$k};
    }
};

my $snapshot_prepare = sub {
    my ($vmid, $snapname, $comment) = @_;

    my $snap;

    my $updatefn =  sub {

	my $conf = load_config($vmid);

	check_lock($conf);

	$conf->{'pve.lock'} = 'snapshot';

	die "snapshot name '$snapname' already used\n"
	    if defined($conf->{snapshots}->{$snapname});

	my $storecfg = PVE::Storage::config();
	die "snapshot feature is not available\n" if !has_feature('snapshot', $conf, $storecfg);

	$snap = $conf->{snapshots}->{$snapname} = {};

	&$snapshot_copy_config($conf, $snap);

	$snap->{'pve.snapstate'} = "prepare";
	$snap->{'pve.snaptime'} = time();
	$snap->{'pve.snapname'} = $snapname;
	$snap->{'pve.snapcomment'} = $comment if $comment;
	$conf->{snapshots}->{$snapname} = $snap;

	PVE::LXC::write_config($vmid, $conf);
    };

    lock_container($vmid, 10, $updatefn);

    return $snap;
};

my $snapshot_commit = sub {
    my ($vmid, $snapname) = @_;

    my $updatefn = sub {

	my $conf = load_config($vmid);

	die "missing snapshot lock\n"
	    if !($conf->{'pve.lock'} && $conf->{'pve.lock'} eq 'snapshot');

	die "snapshot '$snapname' does not exist\n" 
	    if !defined($conf->{snapshots}->{$snapname});

	die "wrong snapshot state\n"
	    if !($conf->{snapshots}->{$snapname}->{'pve.snapstate'} && $conf->{snapshots}->{$snapname}->{'pve.snapstate'} eq "prepare");

	delete $conf->{snapshots}->{$snapname}->{'pve.snapstate'};
	delete $conf->{'pve.lock'};
	$conf->{'pve.parent'} = $snapname;

	PVE::LXC::write_config($vmid, $conf);

    };

    lock_container($vmid, 10 ,$updatefn);
};

sub has_feature {
    my ($feature, $conf, $storecfg, $snapname) = @_;
    #Fixme add other drives if necessary.
    my $err;
    my $volid = $conf->{'pve.volid'};
    $err = 1 if !PVE::Storage::volume_has_feature($storecfg, $feature, $volid, $snapname);

    return $err ? 0 : 1;
}

sub snapshot_create {
    my ($vmid, $snapname, $comment) = @_;

    my $snap = &$snapshot_prepare($vmid, $snapname, $comment);

    my $config = load_config($vmid);

    my $cmd = "/usr/bin/lxc-freeze -n $vmid";
    my $running = check_running($vmid);
    eval {
	if ($running) {
	    PVE::Tools::run_command($cmd);
	};

	my $storecfg = PVE::Storage::config();
	my $volid = $config->{'pve.volid'};

	$cmd = "/usr/bin/lxc-unfreeze -n $vmid";
	if ($running) {
	    PVE::Tools::run_command($cmd);
	};

	PVE::Storage::volume_snapshot($storecfg, $volid, $snapname);
	&$snapshot_commit($vmid, $snapname);
    };
    if(my $err = $@) {
	snapshot_delete($vmid, $snapname, 1);
	die "$err\n";
    }
}

sub snapshot_delete {
    my ($vmid, $snapname, $force) = @_;

    my $snap;

    my $conf;

    my $updatefn =  sub {

	$conf = load_config($vmid);

	$snap = $conf->{snapshots}->{$snapname};

	check_lock($conf);

	die "snapshot '$snapname' does not exist\n" if !defined($snap);

	$snap->{'pve.snapstate'} = 'delete';

	PVE::LXC::write_config($vmid, $conf);
    };

    lock_container($vmid, 10, $updatefn);

    my $storecfg = PVE::Storage::config();

    my $del_snap =  sub {

	check_lock($conf);

	if ($conf->{'pve.parent'} eq $snapname) {
	    if ($conf->{snapshots}->{$snapname}->{'pve.snapname'}) {
		$conf->{'pve.parent'} = $conf->{snapshots}->{$snapname}->{'pve.parent'};
	    } else {
		delete $conf->{'pve.parent'};
	    }
	}

	delete $conf->{snapshots}->{$snapname};

	PVE::LXC::write_config($vmid, $conf);
    };

    my $volid = $conf->{snapshots}->{$snapname}->{'pve.volid'};

    eval {
	PVE::Storage::volume_snapshot_delete($storecfg, $volid, $snapname);
    };
    my $err = $@;

    if(!$err || ($err && $force)) {
	lock_container($vmid, 10, $del_snap);
	if ($err) {
	    die "Can't delete snapshot: $vmid $snapname $err\n";
	}
    }
}

sub snapshot_rollback {
    my ($vmid, $snapname) = @_;

    my $storecfg = PVE::Storage::config();

    my $conf = load_config($vmid);

    my $snap = $conf->{snapshots}->{$snapname};

    die "snapshot '$snapname' does not exist\n" if !defined($snap);

    PVE::Storage::volume_rollback_is_possible($storecfg, $snap->{'pve.volid'},
					      $snapname);

    my $updatefn = sub {

	die "unable to rollback to incomplete snapshot (snapstate = $snap->{snapstate})\n" if $snap->{snapstate};

	check_lock($conf);
	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	eval {
	    lxc_stop($vmid, $authuser, $rpcenv);
	};

	die "unable to rollback vm $vmid: vm is running\n"
	    if check_running($vmid);

	$conf->{'pve.lock'} = 'rollback';

	my $forcemachine;

	# copy snapshot config to current config

	my $tmp_conf = $conf;
	&$snapshot_copy_config($tmp_conf->{snapshots}->{$snapname}, $conf);
	print Dumper $conf, $tmp_conf;
	$conf->{snapshots} = $tmp_conf->{snapshots};
	delete $conf->{'pve.snaptime'};
	delete $conf->{'pve.snapname'};
	$conf->{'pve.parent'} = $snapname;

	PVE::LXC::write_config($vmid, $conf);

    };

    my $unlockfn = sub {
	delete $conf->{'pve.lock'};
	PVE::LXC::write_config($vmid, $conf);
    };

    lock_container($vmid, 10, $updatefn);

    PVE::Storage::volume_snapshot_rollback($storecfg, $conf->{'pve.volid'}, $snapname);

    lock_container($vmid, 5, $unlockfn);
}
1;
