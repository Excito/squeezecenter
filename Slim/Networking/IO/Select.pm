package Slim::Networking::IO::Select;

# $Id: Select.pm 22997 2008-09-01 15:59:20Z andy $

# SqueezeCenter Copyright 2003-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use Exporter::Lite;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::PerfMon;

our @EXPORT = qw(addRead addWrite addError removeRead removeWrite removeError select);

=head1 NAME

Slim::Networking::Select

=head1 SYNOPSIS

Slim::Utils::Select::addRead( $socket, \&callback )

=head1 DESCRIPTION

This module encapsulates all select() related code, handled by SqueezeCenter's main loop.

Usually, you'll want to use higher such as L<Slim::Networking::Async::HTTP>.

=head1 FUNCTIONS

=cut

my $log = logger('server.select');

our $callbacks  = {};

our $selects = {
	'read'     => IO::Select->new, # vectors used for normal select
	'write'    => IO::Select->new,
	'error'    => IO::Select->new,
	'is_read'  => IO::Select->new, # alternatives for select within idleStreams
	'is_write' => IO::Select->new,
	'is_error' => IO::Select->new,
};

our $responseTime = Slim::Utils::PerfMon->new('Response Time', [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.5, 1, 5]);
our $selectTask = Slim::Utils::PerfMon->new('Select Task', [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.5, 1, 5]);

my $endSelectTime;

my $selectInstance = 0;

=head2 addRead( $sock, $callback )

Add a socket to the select loop for reading.

$callback will be notified when the socket is readable.

=cut

sub addRead {

	_updateSelect('read', @_);
}

=head2 removeRead( $sock )

Remove a socket from the select loop and callback notification for reading.

=cut

sub removeRead {
	
	_updateSelect('read', shift);
}

=head2 addWrite( $sock, $callback )

Add a socket to the select loop for writing.

$callback will be notified when the socket is writable..

=cut

sub addWrite {

	_updateSelect('write', @_);
}

=head2 removeWrite( $sock )

Remove a socket from the select loop and callback notification for write.

=cut

sub removeWrite {
	
	_updateSelect('write', shift);
}

=head2 addError( $sock, $callback )

Add a socket to the select loop for error checking.

$callback will be notified when the socket has an error.

=cut

sub addError {

	_updateSelect('error', @_);
}

=head2 removeError( $sock )

Remove a socket from the select loop and callback notification for errors.

=cut

sub removeError {
	
	_updateSelect('error', shift);
}

sub _updateSelect {
	my ($type, $sock, $callback, $idle) = @_;
	
	if (!defined $sock) {

		return;
	}

	if ($callback) {

		$callbacks->{$type}->{$sock} = $callback;

		if (!$selects->{$type}->exists($sock)) {

			$selects->{$type}->add($sock);

			$selects->{'is_'.$type}->add($sock) if $idle;

			if ( $log->is_info ) {
				$log->info(sprintf("fileno: [%s] Adding %s -> %s",
					fileno($sock),
					$type,
					Slim::Utils::PerlRunTime::realNameForCodeRef($callback),
				));
			}
		}
		else {

			if ( $log->is_info ) {
				$log->info(sprintf("fileno: [%d] Not adding %s -> %s, already exists",
					fileno($sock),
					$type,
					Slim::Utils::PerlRunTime::realNameForCodeRef($callback),
				));
			}
		}

	} else {

		delete $callbacks->{$type}->{$sock};

		if ($selects->{$type}->exists($sock)) {

			$selects->{$type}->remove($sock);
		}

		if ($selects->{'is_'.$type}->exists($sock)) {

			$selects->{'is_'.$type}->remove($sock);
		}
		
		if ( $log->is_info ) {
			$log->info(sprintf("fileno: [%d] Removing $type", fileno($sock) || 0));
		}
	}
}

=head2 select( $selectTime, [ $idleStreams ] )

Services all sockets currently in the select loop. Callbacks will be notified
when a socket is readable, writable or has an error.

The only callers are slimserver.pl::idle() and slimserver.pl::idleStreams()

=cut

sub select {
	my $select_time = shift;
	my $idleStreams = shift; # called from idleStreams
	
	if ( $log->is_info ) {
		$log->info( "select( $select_time )" );
	}

	$::perfmon && $endSelectTime && $responseTime->log(Time::HiRes::time() - $endSelectTime);

	my ($r, $w, $e) = ( $idleStreams )
		? IO::Select->select($selects->{'is_read'}, $selects->{'is_write'}, $selects->{'is_error'}, $select_time)
		: IO::Select->select($selects->{'read'}, $selects->{'write'}, $selects->{'error'}, $select_time);

	$::perfmon && ($endSelectTime = Time::HiRes::time());

	# return now if nothing to service - optimisation for most common case
	return unless ( $r || $w || $e );

	$selectInstance = ($selectInstance + 1) % 1000;

	my $thisInstance = $selectInstance;

	my $count   = 0;

	my %handles = (
		'read'  => $r,
		'write' => $w,
		'error' => $e,
	);

	while (my ($type, $handle) = each %handles) {

		foreach my $sock (@$handle) {

			my $callback = $callbacks->{$type}->{$sock};

			if (defined $callback && ref($callback) eq 'CODE') {
				
				$::perfmon && (my $now = Time::HiRes::time());
				
				if ( $log->is_info ) {
					$log->info(sprintf("fileno [%s] %s, calling %s",
						fileno($sock),
						$type,
						Slim::Utils::PerlRunTime::realNameForCodeRef($callback),
					));
				}

				# the socket may have passthrough arguments set
				my $passthrough = ${*$sock}{'passthrough'} || [];
				
				eval { $callback->( $sock, @{$passthrough} ) };

				if ($@) {
					logError("Select task failed: $@");
					
					if ( main::SLIM_SERVICE ) {
						my $name = Slim::Utils::PerlRunTime::realNameForCodeRef($callback);
						SDI::Service::Control->mailError( "IO callback crash: $name", $@ );
					}
				}

				$::perfmon && $now && $selectTask->log(Time::HiRes::time() - $now, undef, $callback);
			}

			$count++;

			# Conditionally readUDP if there are SLIMP3's connected.
			Slim::Networking::UDP::readUDP() if $Slim::Player::SLIMP3::SLIMP3Connected;

			# return if select has been run more recently than thisInstance (if run inside callback)
			return $count if ($thisInstance != $selectInstance);
		}
	}

	return $count;
}

=head1 SEE ALSO

L<IO::Select>

L<Slim::Networking::Async::HTTP>

L<Slim::Networking::Slimproto>

=cut

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
