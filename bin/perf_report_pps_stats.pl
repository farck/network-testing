#!/usr/bin/perl -w

=head1 NAME

 perf_report_pps_stats - From PPS derive per function ns cost by perf report

=head1 SYNOPSIS

 $0 --pps PPS --cpu CPU [options]

 options:
    --pps	Input PPS (Packets Per Sec) measurement
    --cpu	Must limit to single CPU due to nanosec and percent calcs
    --limit     Skip if percent goes below this limit

    --help	Brief usage/help message.
    --man	Full documentation.

=head1 DESCRIPTION

Helper script to (parse and) analyze perf report.

=head1 TODO

Parse --header-only, to make it easier to save info about report.

Implement automatic grouping:
 The manual group-report sorting is error prone, and misguiding as we
 cannot distinguished who e.g. called the page alloc functions.
 Realized that the correct approach is to parse the output of "perf
 script" instead, and fold the stack, and auto-generate the grouping
 based on that.
 Like FlameGraph does (https://github.com/brendangregg/FlameGraph)

=cut

use strict;
use warnings FATAL => 'all';
use Data::Dumper;
use Pod::Usage;
use Getopt::Long;

my $PPS    = 0;
my $CPU    = undef;
my $LIMIT  = 0.10;
my $debug  = 0;
my $dumper = 0;
my $help   = 0;
my $man    = 0;

GetOptions (
    'pps=s'    => \$PPS,
    'cpu=s'    => \$CPU,
    'limit=s'  => \$LIMIT,
    'debug=s'  => \$debug,
    'dumper!'  => \$dumper,
    'help|?'   => sub { Getopt::Long::HelpMessage(-verbose => 1) },
    'man'      => \$man,
    ) or pod2usage(2);
pod2usage(-exitstatus => 0, -verbose => 2) if $man;
pod2usage(-exitstatus => 1, -verbose => 1) unless $PPS;
pod2usage(-exitstatus => 1, -verbose => 1) unless defined $CPU;

# Convert PPS to nanosec
my $NANOSEC = (1/$PPS*10**9);

# Keep track of functions displayed. Purpose is to display the
# negative list if functions that were not displayed in one of the
# special reports.
my %func_visited;

sub collect_report($$) {
    # Parse perf report and return hash
    my ($cpu, $nanosec) = @_;
    my %hash;
    $hash{"stat"}{"nanosec"} = $nanosec;
    $hash{"stat"}{"nanosec_sum"} = 0;
    $hash{"stat"}{"percent_sum"} = 0;
    $hash{"stat"}{"pps"} = $PPS;
    open(REPORT, "sudo perf report --no-children -f --stdio -C $cpu |");
    # open(REPORT, "sudo perf report --no-children --stdio --header -C $cpu |");
    while (defined(my $line = <REPORT>)) {
	chomp($line);
	#print "LINE: $line\n" if $debug;
	# Example of line to match:
	#     18.93%  ksoftirqd/3    [kernel.vmlinux]  [k] __napi_alloc_skb
	#
	# Fairly coase matching, just want the % and function name "symbol"
	# problem is "Command" can contain whitespaces
	if ($line =~ m/\s+(\d+\.\d+)%\s\s(.+)\s+(\S+)\s*$/) {
	    my $percent = $1;
	    my $skip    = $2;
	    my $sym     = $3;
	    my $ns = 0;
	    if (not defined $hash{"func"}{$sym}{"percent"}) {
		$hash{"func"}{$sym}{"percent"} = $percent;
		$ns = $nanosec * ($percent/100);
		$hash{"func"}{$sym}{"nanosec"} = $ns;
	    } else {
		# Handle if defined before
		print "***WARN***: function $sym double defined ($percent)\n";
		$hash{"func"}{$sym}{"percent"} += $percent;
		# Subtract pref nanosec from "nanosec_sum"
		my $ns_prev = $hash{"func"}{$sym}{"nanosec"};
		$hash{"stat"}{"nanosec_sum"} -= $ns_prev;
		# Calc new nanosec based on sum percentage
		my $p_sum = $hash{"func"}{$sym}{"percent"};
		$ns = $nanosec * ($p_sum/100);
		$hash{"func"}{$sym}{"nanosec"} = $ns;
	    }
	    $hash{"stat"}{"percent_sum"} += $percent;
	    $hash{"stat"}{"nanosec_sum"} += $ns;

	    print "PARSED: $line =>\n\t" .
		"p:\"$percent\" skip:\"$skip\" sym:\"$sym\"\n" if ($debug > 2);
	} else {
	    print "WARN: could not parse line:\"$line\"\n" if ($debug > 1);
	}
    }
    close(REPORT);
    return \%hash;
}

sub print_func_keys($$$) {
    my $stat = shift;
    my $keys_ref = shift;
    my $limit = shift;

    my @keys = @$keys_ref;

    # Pullout hash containing function names.
    my $f = $stat->{"func"};
    # Get the total nanosec stored in "stat"
    my $nanosec_total = $stat->{"stat"}{"nanosec"};
    # Stat variables;
    my $sum_percent = 0;
    my $sum_ns      = 0;

    foreach my $func (sort
		      { $f->{$b}{"percent"} <=> $f->{$a}{"percent"} }
		      @keys)
    {
	my $percent = $f->{$func}{"percent"};
	my $ns      = $f->{$func}{"nanosec"};
	$sum_percent += $percent;
	$sum_ns      += $ns;
	if ($percent < $limit) {
	    print " (Percent limit($limit%) stop at \"$func\")\n";
	    last;
	}
	printf(" %5.2f %s ~= %4.1f ns <= %s\n", $percent, "%", $ns , $func);
    }
    # Calc nanosecs from percent sum, as nanosec round-down at low
    # percentage will be cancled out
    my $calc_ns = $nanosec_total * ($sum_percent/100);
    printf(" Sum: %5.2f %s => calc: %.1f ns (sum: %.1f ns) => Total: %.1f ns\n\n",
	   $sum_percent, "%", $calc_ns, $sum_ns, $nanosec_total);
}

sub show_report_keys($$$$) {
    my $stat = shift;
    my $keys_ref = shift;
    my $pattern_ref = shift;
    my $limit = shift;

    # Pullout hash containing function names.
    my $f = $stat->{"func"};
    #print Dumper($f) if $dumper;

    # Limiting functions/keys to report on, but need to remove
    # functions/keys not in the report.
    #
    # Build hash with valid keys, to avoid adding dublicated when
    # pattern matching against functions
    my %hash;
    foreach my $func (@$keys_ref) {
	if (defined $f->{$func}) {
	    $hash{$func} += 1;
	    $func_visited{$func} += 1 if ($hash{$func} == 1);
	}
    }
    # Also add keys matching a pattern, mark hash to avoid dublicates
    my @pattern  = @$pattern_ref;
    my @all_func = keys %$f;
    foreach my $match (@pattern) {
	foreach my $func (@all_func) {
	    if ($func =~ m/$match/i ) {
		$hash{$func} += 1;
		$func_visited{$func} += 1 if ($hash{$func} == 1);
	    }
	}
    }
    # Extract keys for hash, to avoid dublicates
    my @keys = keys %hash;
    # print Dumper(\@keys) if $dumper;

    print_func_keys($stat, \@keys, $limit);
}

sub show_negative_report($$) {
    my $stat = shift;
    my $visited_ref = shift;

    # Pullout hash containing function names.
    my $f = $stat->{"func"};

    # Find all keys/func not marked in the visited hash
    my @all_func = keys %$f;
    my @neg_keys;
    foreach my $func (@all_func) {
	if (not defined $visited_ref->{$func}) {
	    push @neg_keys, $func;
	} else {
	    # Were any of the visited functions "double" included in
	    # the detailed reports?
	    my $visit_cnt = $visited_ref->{$func};
	    if ($visit_cnt > 1) {
		printf("Double(cnt:%d) displayed function: %s\n",
		       $visit_cnt, $func)
	    }
	}
    }

    print "Negative Report: functions NOT included in group reports::\n";
    print_func_keys($stat, \@neg_keys, 0);
}

sub show_report($) {
    my $stat = shift;
    my @pattern = ();

    # Pullout hash containing function names.
    my $f = $stat->{"func"};
    # Extract keys here, for all functions
    my @keys = keys %$f;

    print "Report: ALL functions ::\n";
    show_report_keys($stat,\@keys, \@pattern, $LIMIT);
}

my $STATS = collect_report($CPU, $NANOSEC);
show_report($STATS);
# Reset the functions "visited" hash, after the normal show_report
# this way we only look at special reports.
%func_visited = ();

sub show_report_related($@) {
    my $stat = shift;
    my @pattern = @_;
    my @func = ();
    print "Group-report: related to pattern \"" . join('+', @pattern) . "\" ::\n";
    show_report_keys($STATS,\@func, \@pattern, 0);
}

sub show_report_dma($) {
    my $stat = shift;
    my @func = qw/
swiotlb_dma_mapping_error
unmap_single
/;
    my @pattern = qw/
dma
swiotlb
/;
    print "Group-report: DMA functions ::\n";
    show_report_keys($STATS,\@func, \@pattern, 0);
}

sub show_report_pagefrag($) {
    my $stat = shift;
    my @func = qw/
__free_page_frag
__alloc_page_frag
__free_pages_ok
free_pages_prepare
get_pfnblock_flags_mask
get_page_from_freelist
free_one_page
__alloc_pages_nodemask
__mod_zone_page_state
mod_zone_page_state
next_zones_zonelist
__rmqueue
__zone_watermark_ok
__inc_zone_state
zone_statistics
/;
    my @pattern = qw/
page_frag
/;
    print "Group-report: page_frag_cache functions ::\n";
    show_report_keys($STATS,\@func, \@pattern, 0);
}

sub show_report_slab($) {
    my $stat = shift;
    my @func_kmem = qw/
kmem_cache_free
kmem_cache_free_bulk
kmem_cache_alloc
kmem_cache_alloc_bulk
__slab_free
___slab_alloc
get_partial_node
put_cpu_partial
/;
    my @func_kmem_pattern = qw/
kmem_cache
cmpxchg_double_slab
cmpxchg
slab
get_partial_node
unfreeze_partials
/;
    print "Group-report: kmem_cache/SLUB allocator functions ::\n";
    show_report_keys($STATS,\@func_kmem, \@func_kmem_pattern, 0);
}

sub show_report_netstack($) {
    my $stat = shift;
    my @func = qw/
fib_table_lookup
fib_validate_source
udp_v4_early_demux
ip_rcv_finish
ip_rcv
ip_forward
ip_forward_finish
ip_output
dev_hard_start_xmit
dev_queue_xmit
__dev_queue_xmit
sch_direct_xmit
dql_completed
napi_complete_done
__napi_schedule
ip_route_input_noref
find_exception
/;
    my @pattern = qw/
ip_finish_output
_pick_tx
_gro_\W+$
ip_route_
net_.._action
softirq
/;
    print "Group-report: Core network-stack functions ::\n";
    show_report_keys($STATS,\@func, \@pattern, 0);
}

sub show_report_gro($) {
    my $stat = shift;
    my @func = qw/
/;
    my @pattern = qw/
^\w+_gro_\w++$
/;
    print "Group-report: GRO network-stack functions ::\n";
    show_report_keys($STATS,\@func, \@pattern, 0);
}


# Order of detailed group reports:
show_report_related($STATS, "eth_type_trans|mlx5|ixgbe|__iowrite64_copy");
show_report_dma($STATS);
show_report_pagefrag($STATS);

show_report_slab($STATS);
show_report_related($STATS, "skb");
show_report_netstack($STATS);
show_report_gro($STATS);

#show_report_related($STATS, "page");
show_report_related($STATS, "spin_.*lock|mutex");


#print Dumper($STATS) if $dumper;
print Dumper(\%func_visited) if $dumper;
print "Total PPS:$PPS NANOSEC:$NANOSEC\n" if $dumper;

show_negative_report($STATS, \%func_visited);

__END__

=head1 ALTERNATIVES

 There is suppose to be a perl module integration with perf, but I
 could not get it to work. See man perf-script-perl(1).

 Also see FlameGraph https://github.com/brendangregg/FlameGraph
 for a graphical representation.

=head1 AUTHOR

 Jesper Dangaard Brouer <netoptimizer@brouer.com>

=cut
