# cgroup handler
#
# This package should deal with figuring out the right cgroup path for a
# container (via the command socket), reading and writing cgroup values, and
# handling cgroup v1 & v2 differences.
#
# Note that the long term plan is to have resource manage functions intead of
# dealing with cgroup files on the outside.

package PVE::LXC::CGroup;

use strict;
use warnings;

use POSIX qw();

use PVE::ProcFSTools;
use PVE::Tools qw(
    file_get_contents
    file_read_firstline
);

use PVE::LXC::Command;

# We don't want to do a command socket round trip for every cgroup read/write,
# so any cgroup function needs to have the container's path cached, so this
# package has to be instantiated.
#
# LXC keeps separate paths by controller (although they're normally all the
# same, in our # case anyway), so we cache them by controller as well.
sub new {
    my ($class, $vmid) = @_;

    my $self = { vmid => $vmid };

    return bless $self, $class;
}

my $CPUSET_BASE = undef;
# Find the cpuset cgroup controller.
#
# This is a function, not a method!
sub cpuset_controller_path() {
    if (!defined($CPUSET_BASE)) {
	my $CPUSET_PATHS = [
	    # legacy cpuset cgroup:
	    ['/sys/fs/cgroup/cpuset',  'cpuset.effective_cpus'],
	    # pure cgroupv2 environment:
	    ['/sys/fs/cgroup',         'cpuset.cpus.effective'],
	    # hybrid, with cpuset moved to cgroupv2
	    ['/sys/fs/cgroup/unified', 'cpuset.cpus.effective'],
	];

	my ($result) = grep { -f "$_->[0]/$_->[1]" } @$CPUSET_PATHS;
	die "failed to find cpuset controller\n" if !defined($result);

	$CPUSET_BASE = $result->[0];
    }

    return $CPUSET_BASE;
}

my $CGROUP_MODE = undef;
# Figure out which cgroup mode we're operating under:
#
# Returns 1 if cgroupv1 controllers exist (hybrid or legacy mode), and 2 in a
# cgroupv2-only environment.
#
# This is a function, not a method!
sub cgroup_mode() {
    if (!defined($CGROUP_MODE)) {
	my ($v1, $v2) = PVE::LXC::get_cgroup_subsystems();
	if (keys %$v1) {
	    # hybrid or legacy mode
	    $CGROUP_MODE = 1;
	} elsif ($v2) {
	    $CGROUP_MODE = 2;
	}
    }

    die "unknown cgroup mode\n" if !defined($CGROUP_MODE);
    return $CGROUP_MODE;
}

# Get a subdirectory (without the cgroup mount point) for a controller.
#
# If `$controller` is `undef`, get the unified (cgroupv2) path.
#
# Note that in cgroup v2, lxc uses the activated controller names
# (`cgroup.controllers` file) as list of controllers for the unified hierarchy,
# so this returns a result when a `controller` is provided even when using
# a pure cgroupv2 setup.
my sub get_subdir {
    my ($self, $controller, $limiting) = @_;

    my $entry_name = $controller || 'unified';
    my $entry = ($self->{controllers}->{$entry_name} //= {});

    my $kind = $limiting ? 'limit' : 'ns';
    my $path = $entry->{$kind};

    return $path if defined $path;

    $path = PVE::LXC::Command::get_cgroup_path(
	$self->{vmid},
	$controller,
	$limiting,
    ) or return undef;

    # untaint:
    if ($path =~ /\.\./) {
	die "lxc returned suspicious path: '$path'\n";
    }
    ($path) = ($path =~ /^(.*)$/s);

    $entry->{$kind} = $path;

    return $path;
}

# Get a path for a controller.
#
# `$controller` may be `undef`, see get_subdir above for details.
sub get_path {
    my ($self, $controller) = @_;

    my $path = get_subdir($self, $controller)
	or return undef;

    # The main mount point we currenlty assume to be in a standard location.
    return "/sys/fs/cgroup/$path" if cgroup_mode() == 2;
    return "/sys/fs/cgroup/unified/$path" if !defined($controller);
    return "/sys/fs/cgroup/$controller/$path";
}

# Parse a 'Nested keyed' file:
#
# See kernel documentation `admin-guide/cgroup-v2.rst` 4.1.
my sub parse_nested_keyed_file($) {
    my ($data) = @_;
    my $res = {};
    foreach my $line (split(/\n/, $data)) {
	my ($key, @values) = split(/\s+/, $line);

	my $d = ($res->{$key} = {});

	foreach my $value (@values) {
	    if (my ($key, $value) = ($value =~ /^([^=]+)=(.*)$/)) {
		$d->{$key} = $value;
	    } else {
		warn "bad key=value pair in nested keyed file\n";
	    }
	}
    }
    return $res;
}

# Parse a 'Flat keyed' file:
#
# See kernel documentation `admin-guide/cgroup-v2.rst` 4.1.
my sub parse_flat_keyed_file($) {
    my ($data) = @_;
    my $res = {};
    foreach my $line (split(/\n/, $data)) {
	if (my ($key, $value) = ($line =~ /^(\S+)\s+(.*)$/)) {
	    $res->{$key} = $value;
	} else {
	    warn "bad 'key value' pair in flat keyed file\n";
	}
    }
    return $res;
}

# Parse out 'diskread' and 'diskwrite' values from I/O stats for this container.
sub get_io_stats {
    my ($self) = @_;

    my $res = {
	diskread => 0,
	diskwrite => 0,
    };

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('io'))) {
	    # cgroupv2 environment, io controller enabled
	    my $io_stat = file_get_contents("$path/io.stat");

	    my $data = parse_nested_keyed_file($io_stat);
	    foreach my $dev (keys %$data) {
		my $dev = $data->{$dev};
		if (my $b = $dev->{rbytes}) {
		    $res->{diskread} += $b;
		}
		if (my $b = $dev->{wbytes}) {
		    $res->{diskread} += $b;
		}
	    }
	} else {
	    # io controller not enabled or container not running
	    return undef;
	}
    } elsif (defined(my $path = $self->get_path('blkio'))) {
	# cgroupv1 environment:
	my $io = file_get_contents("$path/blkio.throttle.io_service_bytes_recursive");
	foreach my $line (split(/\n/, $io)) {
	    if (my ($type, $bytes) = ($line =~ /^\d+:\d+\s+(Read|Write)\s+(\d+)$/)) {
		$res->{diskread} += $bytes if $type eq 'Read';
		$res->{diskwrite} += $bytes if $type eq 'Write';
	    }
	}
    } else {
	# container not running
	return undef;
    }

    return $res;
}

# Read utime and stime for this container from the cpuacct cgroup.
# Values are in milliseconds!
sub get_cpu_stat {
    my ($self) = @_;

    my $res = {
	utime => 0,
	stime => 0,
    };

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('cpu'))) {
	    my $data = eval { file_get_contents("$path/cpu.stat") };

	    # or no io controller available:
	    return undef if !defined($data);

	    $data = parse_flat_keyed_file($data);
	    $res->{utime} = int($data->{user_usec} / 1000);
	    $res->{stime} = int($data->{system_usec} / 1000);
	} else {
	    # memory controller not enabled or container not running
	    return undef;
	}
    } elsif (defined(my $path = $self->get_path('cpuacct'))) {
	# cgroupv1 environment:
	my $clock_ticks = POSIX::sysconf(&POSIX::_SC_CLK_TCK);
	my $clk_to_usec = 1000 / $clock_ticks;

	my $data = parse_flat_keyed_file(file_get_contents("$path/cpuacct.stat"));
	$res->{utime} = int($data->{user} * $clk_to_usec);
	$res->{stime} = int($data->{system} * $clk_to_usec);
    } else {
	# container most likely isn't running
	return undef;
    }

    return $res;
}

# Parse some memory data from `memory.stat`
sub get_memory_stat {
    my ($self) = @_;

    my $res = {
	mem => 0,
	swap => 0,
    };

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('memory'))) {
	    my $mem = file_get_contents("$path/memory.current");
	    my $swap = file_get_contents("$path/memory.swap.current");

	    chomp ($mem, $swap);

	    # FIXME: For the cgv1 equivalent of `total_cache` we may need to sum up
	    # the values in `memory.stat`...

	    $res->{mem} = $mem;
	    $res->{swap} = $swap;
	} else {
	    # memory controller not enabled or container not running
	    return undef;
	}
    } elsif (defined(my $path = $self->get_path('memory'))) {
	# cgroupv1 environment:
	my $stat = parse_flat_keyed_file(file_get_contents("$path/memory.stat"));
	my $mem = file_get_contents("$path/memory.usage_in_bytes");
	my $memsw = file_get_contents("$path/memory.memsw.usage_in_bytes");
	chomp ($mem, $memsw);

	$res->{mem} = $mem - $stat->{total_cache};
	$res->{swap} = $memsw - $mem;
    } else {
	# container most likely isn't running
	return undef;
    }

    return $res;
}

# Change the memory limit for this container.
#
# Dies on error (including a not-running or currently-shutting-down guest).
sub change_memory_limit {
    my ($self, $mem_bytes, $swap_bytes) = @_;

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('memory'))) {
	    PVE::ProcFSTools::write_proc_entry("$path/memory.swap.max", $swap_bytes)
		if defined($swap_bytes);
	    PVE::ProcFSTools::write_proc_entry("$path/memory.max", $mem_bytes)
		if defined($mem_bytes);
	    return 1;
	}
    } elsif (defined(my $path = $self->get_path('memory'))) {
	# With cgroupv1 we cannot control memory and swap limits separately.
	# This also means that since the two values aren't independent, we need to handle
	# growing and shrinking separately.
	my $path_mem = "$path/memory.limit_in_bytes";
	my $path_memsw = "$path/memory.memsw.limit_in_bytes";

	my $old_mem_bytes = file_get_contents($path_mem);
	my $old_memsw_bytes = file_get_contents($path_memsw);
	chomp($old_mem_bytes, $old_memsw_bytes);

	$mem_bytes //= $old_mem_bytes;
	my $memsw_bytes = defined($swap_bytes) ? ($mem_bytes + $swap_bytes) : $old_memsw_bytes;

	if ($memsw_bytes > $old_memsw_bytes) {
	    # Growing the limit means growing the combined limit first, then pulling the
	    # memory limitup.
	    PVE::ProcFSTools::write_proc_entry($path_memsw, $memsw_bytes);
	    PVE::ProcFSTools::write_proc_entry($path_mem, $mem_bytes);
	} else {
	    # Shrinking means we first need to shrink the mem-only memsw cannot be
	    # shrunk below it.
	    PVE::ProcFSTools::write_proc_entry($path_mem, $mem_bytes);
	    PVE::ProcFSTools::write_proc_entry($path_memsw, $memsw_bytes);
	}
	return 1;
    }

    die "trying to change memory cgroup values: container not running\n";
}

# Change the cpu quota for a container.
#
# Dies on error (including a not-running or currently-shutting-down guest).
sub change_cpu_quota {
    my ($self, $quota, $period) = @_;

    die "quota without period not allowed\n" if !defined($period) && defined($quota);

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('cpu'))) {
	    # cgroupv2 environment, an undefined (unlimited) quota is defined as "max"
	    # in this interface:
	    $quota //= 'max'; # unlimited
	    if (defined($quota)) {
		PVE::ProcFSTools::write_proc_entry("$path/cpu.max", "$quota $period");
	    } else {
		# we're allowed to only write the quota:
		PVE::ProcFSTools::write_proc_entry("$path/cpu.max", 'max');
	    }
	    return 1;
	}
    } elsif (defined(my $path = $self->get_path('cpu'))) {
	$quota //= -1; # unlimited
	$period //= -1;
	PVE::ProcFSTools::write_proc_entry("$path/cpu.cfs_period_us", $period);
	PVE::ProcFSTools::write_proc_entry("$path/cpu.cfs_quota_us", $quota);
	return 1;
    }

    die "trying to change cpu quota cgroup values: container not running\n";
}

# Change the cpu "shares" for a container.
#
# In cgroupv1 we used a value in `[0..500000]` with a default of 1024.
#
# In cgroupv2 we do not have "shares", we have "weights" in the range
# of `[1..10000]` with a default of 100.
#
# Since the default values don't match when scaling linearly, we use the
# values we get as-is and simply error for values >10000 in cgroupv2.
#
# It is left to the user to figure this out for now.
#
# Dies on error (including a not-running or currently-shutting-down guest).
sub change_cpu_shares {
    my ($self, $shares, $cgroupv1_default) = @_;

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('cpu'))) {
	    # the cgroupv2 documentation defines the default to 100
	    $shares //= 100;
	    die "cpu weight (shares) must be in range [1, 10000]\n" if $shares < 1 || $shares > 10000;
	    PVE::ProcFSTools::write_proc_entry("$path/cpu.weight", $shares);
	    return 1;
	}
    } elsif (defined(my $path = $self->get_path('cpu'))) {
	$shares //= 100;
	PVE::ProcFSTools::write_proc_entry("$path/cpu.shares", $shares // $cgroupv1_default);
	return 1;
    }

    # container most likely isn't running
    die "trying to change cpu shares/weight cgroup values: container not running\n";
}

1;
