package Slim::Networking::Async::DNS;

# $Id: DNS.pm 31443 2010-10-16 16:30:32Z agrundman $

# Squeezebox Server Copyright 2003-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# This class handles async DNS lookups.  It will also cache lookups for
# TTL.

use strict;

use AnyEvent::DNS;
use Tie::Cache::LRU;

use Slim::Utils::Log;
use Slim::Utils::Misc;

# Cached lookups
tie my %cache, 'Tie::Cache::LRU', 100;

my $log = logger('network.asyncdns');

BEGIN {
	# Disable AnyEvent::DNS's use of OpenDNS
	@AnyEvent::DNS::DNS_FALLBACK = ();
}

sub init { }

sub resolve {
	my ( $class, $args ) = @_;
	
	my $host = $args->{host};
	
	if ( main::SLIM_SERVICE && $host =~ /^www\.(squeezenetwork|mysqueezebox)\.com$/ ) {
		# Check /etc/hosts on MySB to determine internal datacenter address instead of public
		my $localip;
		my $mtime = (stat('/etc/hosts'))[9];
		
		if ( my $cached = $cache{$host} ) {
			if ( $cached->{mtime} == $mtime ) {
				my $addr = $cached->{addr};
				main::DEBUGLOG && $log->is_debug && $log->debug( "Using cached DNS response $addr for $host" );

				$args->{cb}->( $addr, @{ $args->{pt} || [] } );
				return;
			}
		}
		
		open my $fh, '<', '/etc/hosts';
		my $etchosts = do { local $/; <$fh> };
		close $fh;
		
		for my $line ( split /\n/, $etchosts ) {
			next unless $line =~ /^\d/;
			my ($ip, $hostnames) = $line =~ /^([\d.]+)\s(.+)/;
			if ( $hostnames =~ /$host/i ) {
				$localip = $ip;
				last;
			}
		}
		
		if ($localip) {
			$cache{$host} = {
				addr  => $localip,
				mtime => $mtime,
			};
			
			$args->{cb}->( $localip, @{ $args->{pt} || [] } );
			return;
		}
	}
	
	# Check cache
	if ( exists $cache{ $host } ) {
		if ( $cache{ $host }->{expires} > time() ) {
			my $addr = $cache{ $host }->{addr};
			main::DEBUGLOG && $log->is_debug && $log->debug( "Using cached DNS response $addr for $host" );
			
			$args->{cb}->( $addr, @{ $args->{pt} || [] } );
			return;
		}
		else {
			delete $cache{ $host };
		}
	}
	
	AnyEvent::DNS::resolver->resolve( $host => 'a', sub {
		my $res = shift;
		
		if ( !$res ) {
			# Lookup failed
			main::DEBUGLOG && $log->is_debug && $log->debug("Lookup failed for $host");
			
			$args->{ecb} && $args->{ecb}->( @{ $args->{pt} || [] } );
			return;
		}
		
		my $addr = $res->[3];
		my $ttl	 = $res->[4];
		
		main::DEBUGLOG && $log->is_debug && $log->debug( "Got DNS response $addr for $host (ttl $ttl)" );
		
		# cache lookup for ttl
		if ( $ttl ) {
			$cache{$host} = {
				addr    => $addr,
				expires => AnyEvent->now + $ttl,
			};
		}
		
		$args->{cb}->( $addr, @{ $args->{pt} || [] } );
	} );
}

1;