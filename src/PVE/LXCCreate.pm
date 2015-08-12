package PVE::LXCCreate;

use strict;
use warnings;
use File::Basename;
use File::Path;
use Data::Dumper;

use PVE::Storage;
use PVE::LXC;
use PVE::LXCSetup;
use PVE::VZDump::ConvertOVZ;

sub next_free_nbd_dev {
    
    for(my $i = 0;;$i++) {
	my $dev = "/dev/nbd$i";
	last if ! -b $dev;
	next if -f "/sys/block/nbd$i/pid"; # busy
	return $dev;
    }
    die "unable to find free nbd device\n";
}

sub restore_archive {
    my ($archive, $rootdir, $conf) = @_;

    my $userns_cmd = [];

#    we always use the same mapping: 'b:0:100000:65536'
#    if ($conf->{'lxc.id_map'}) {
#	$userns_cmd = ['lxc-usernsexec', '-m', 'b:0:100000:65536', '--'];
#	PVE::Tools::run_command(['chown', '-R', '100000:100000', $rootdir]);
#    }

    my $cmd = [@$userns_cmd, 'tar', 'xpf', $archive, '--numeric-owner', '--totals',
	    '--sparse', '-C', $rootdir];

    push @$cmd, '--anchored';
    push @$cmd, '--exclude' , './dev/*';

    if ($archive eq '-') {
	print "extracting archive from STDIN\n";
	PVE::Tools::run_command($cmd, input => "<&STDIN");
    } else {
	print "extracting archive '$archive'\n";
	PVE::Tools::run_command($cmd);
    }
    
    # determine file type of /usr/bin/file itself to get guests' architecture
    $cmd = [@$userns_cmd, '/usr/bin/file', '-b', '-L', "$rootdir/usr/bin/file"];
    PVE::Tools::run_command($cmd, outfunc => sub {
	shift =~ /^ELF (\d{2}-bit)/; # safely assumes x86 linux
	my $arch_str = $1;
	$conf->{'arch'} = 'amd64'; # defaults to 64bit
	if(defined($arch_str)) {
	    $conf->{'arch'} = 'i386' if $arch_str =~ /32/;
	    print "Detected container architecture: $conf->{'arch'}\n";
	} else {
	    print "CT architecture detection failed, falling back to amd64.\n" .
	          "Edit the config in /etc/pve/nodes/{node}/lxc/{vmid}/config " .
	          "to set another architecture.\n";
	}
    });
}

sub tar_archive_search_conf {
    my ($archive) = @_;

    die "ERROR: file '$archive' does not exist\n" if ! -f $archive;

    my $pid = open(my $fh, '-|', 'tar', 'tf', $archive) ||
       die "unable to open file '$archive'\n";

    my $file;
    while (defined($file = <$fh>)) {
	if ($file =~ m!^(\./etc/vzdump/(pct|vps)\.conf)$!) {
	    $file = $1; # untaint
	    last;
	}
    }

    kill 15, $pid;
    waitpid $pid, 0;
    close $fh;

    die "ERROR: archive contains no configuration file\n" if !$file;
    chomp $file;

    return $file;
}

sub recover_config {
    my ($archive) = @_;

    my $conf_file = tar_archive_search_conf($archive);
    
    my $raw = '';
    my $out = sub {
	my $output = shift;
	$raw .= "$output\n";
    };

    PVE::Tools::run_command(['tar', '-xpOf', $archive, $conf_file, '--occurrence'], outfunc => $out);

    my $conf;
    my $disksize;

    if ($conf_file =~ m/pct\.conf/) {

	$conf = PVE::LXC::parse_pct_config("/lxc/0.conf" , $raw);

	delete $conf->{snapshots};
	
	if (defined($conf->{rootfs})) {
	    my $rootinfo = PVE::LXC::parse_ct_mountpoint($conf->{rootfs});
	    $disksize = $rootinfo->{size} if defined($rootinfo->{size});
	}
	
    } elsif ($conf_file =~ m/vps\.conf/) {
	
	($conf, $disksize) = PVE::VZDump::ConvertOVZ::convert_ovz($raw);
	
    } else {

       die "internal error";
    }

    return wantarray ? ($conf, $disksize) : $conf;
}

sub restore_and_configure {
    my ($vmid, $archive, $rootdir, $conf, $password, $restore) = @_;

    restore_archive($archive, $rootdir, $conf);

    if (!$restore) {
	my $lxc_setup = PVE::LXCSetup->new($conf, $rootdir); # detect OS

	PVE::LXC::write_config($vmid, $conf); # safe config (after OS detection)
	$lxc_setup->post_create_hook($password);
    } else {
	# restore: try to extract configuration from archive

	my $pct_cfg_fn = "$rootdir/etc/vzdump/pct.conf";
	my $ovz_cfg_fn = "$rootdir/etc/vzdump/vps.conf";
	if (-f $pct_cfg_fn) {
	    my $raw = PVE::Tools::file_get_contents($pct_cfg_fn);
	    my $oldconf = PVE::LXC::parse_pct_config("/lxc/$vmid.conf", $raw);

	    foreach my $key (keys %$oldconf) {
		next if $key eq 'digest' || $key eq 'rootfs' || $key eq 'snapshots';
		$conf->{$key} = $oldconf->{$key} if !defined($conf->{$key});
	    }
	    
	} elsif (-f $ovz_cfg_fn) {
	    print "###########################################################\n";
	    print "Converting OpenVZ configuration to LXC.\n";
	    print "Please check the configuration and reconfigure the network.\n";
	    print "###########################################################\n";

	    my $raw = PVE::Tools::file_get_contents($ovz_cfg_fn);
	    my $oldconf = PVE::VZDump::ConvertOVZ::convert_ovz($raw);
	    foreach my $key (keys %$oldconf) {
		$conf->{$key} = $oldconf->{$key} if !defined($conf->{$key});
	    }

	} else {
	    print "###########################################################\n";
	    print "Backup archive does not contain any configuration\n";
	    print "###########################################################\n";
	}
    }
}

# use new subvolume API
sub create_rootfs_subvol {
    my ($storage_conf, $storage, $volid, $vmid, $conf, $archive, $password, $restore) = @_;

    my $private = PVE::Storage::path($storage_conf, $volid);
    (-d $private) || die "unable to get container private dir '$private' - $!\n";

    restore_and_configure($vmid, $archive, $private, $conf, $password, $restore);
}

# direct mount
sub create_rootfs_dev {
    my ($storage_conf, $storage, $volid, $vmid, $conf, $archive, $password, $restore) = @_;

    my $image_path = PVE::Storage::path($storage_conf, $volid);
    
    my $cmd = ['mkfs.ext4', $image_path];
    PVE::Tools::run_command($cmd);

    my $mountpoint;

    eval {
	my $tmp = "/var/lib/lxc/$vmid/rootfs";
	File::Path::mkpath($tmp);
	PVE::Tools::run_command(['mount', '-t', 'ext4', $image_path, $tmp]);
	$mountpoint = $tmp;

	restore_and_configure($vmid, $archive, $mountpoint, $conf, $password, $restore);
    };
    if (my $err = $@) {
	if ($mountpoint) {
	    eval { PVE::Tools::run_command(['umount', $mountpoint]) };
	    warn $@ if $@;
	} 
	die $err;
    }

    PVE::Tools::run_command(['umount', '-l', $mountpoint]);
}

# create a raw file, then loop mount
sub create_rootfs_dir_loop {
    my ($storage_conf, $storage, $volid, $vmid, $conf, $archive, $password, $restore) = @_;

    my $image_path = PVE::Storage::path($storage_conf, $volid);

    my $cmd = ['mkfs.ext4', $image_path];
    PVE::Tools::run_command($cmd);

    my $mountpoint;

    my $loopdev;
    eval {
	my $parser = sub {
	    my $line = shift;
	    $loopdev = $line if $line =~m|^/dev/loop\d+$|;
	};
	PVE::Tools::run_command(['losetup', '--find', '--show', $image_path], outfunc => $parser);

	my $tmp = "/var/lib/lxc/$vmid/rootfs";
	File::Path::mkpath($tmp);
	PVE::Tools::run_command(['mount', '-t', 'ext4', $loopdev, $tmp]);
	$mountpoint = $tmp;

	restore_and_configure($vmid, $archive, $mountpoint, $conf, $password, $restore);
    };
    if (my $err = $@) {
	if ($mountpoint) {
	    eval { PVE::Tools::run_command(['umount', '-d', $mountpoint]) };
	    warn $@ if $@;
	} else {
	    eval { PVE::Tools::run_command(['losetup', '-d', $loopdev]) if $loopdev; };
	    warn $@ if $@;
	}
	die $err;
    }

    PVE::Tools::run_command(['umount', '-l', '-d', $mountpoint]);
}

sub create_rootfs {
    my ($storage_cfg, $storage, $volid, $vmid, $conf, $archive, $password, $restore) = @_;

    my $config_fn = PVE::LXC::config_file($vmid);
    if (-f $config_fn) {
	die "container exists" if !$restore; # just to be sure

	my $old_conf = PVE::LXC::load_config($vmid);
	
	# destroy old container volume
	PVE::LXC::destory_lxc_container($storage_cfg, $vmid, $old_conf);

	# do not copy all settings to restored container
	foreach my $opt (qw(rootfs digest snapshots)) {
	    delete $old_conf->{$opt};
	}
	PVE::LXC::update_pct_config($vmid, $conf, 0, $old_conf);

	PVE::LXC::create_config($vmid, $conf);

    } else {
	
	PVE::LXC::create_config($vmid, $conf);
    }

    my ($vtype, undef, undef, undef, undef, $isBase, $format) =
	PVE::Storage::parse_volname($storage_cfg, $volid);
	
    die "got strange vtype '$vtype'\n" if $vtype ne 'images';
    
    die "unable to install into base volume" if $isBase;

    if ($format eq 'subvol') {
	create_rootfs_subvol($storage_cfg, $storage, $volid, $vmid, $conf, $archive, $password, $restore);
    } elsif ($format eq 'raw') {
	my $scfg = PVE::Storage::storage_config($storage_cfg, $storage);
	if ($scfg->{path}) {
	    create_rootfs_dir_loop($storage_cfg, $storage, $volid, $vmid, $conf, $archive, $password, $restore);
	} elsif ($scfg->{type} eq 'drbd') {
	    create_rootfs_dev($storage_cfg, $storage, $volid, $vmid, $conf, $archive, $password, $restore);
	} else {
	    die "unable to create containers on storage type '$scfg->{type}'\n";
	}
    } else {
	die "unsupported image format '$format'\n";
    }
}

1;
