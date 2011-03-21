package Slim::Networking::Slimproto;

# $Id: Slimproto.pm 25681 2009-03-24 15:03:19Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use Slim::Utils::Errno;
use FindBin qw($Bin);
use Socket qw(inet_ntoa SOMAXCONN);
use IO::Socket qw(sockaddr_in);
#use FileHandle;
use Sys::Hostname;
use File::Spec::Functions qw(:ALL);
use Math::VecStat;
use Scalar::Util qw(blessed);

use Slim::Networking::Select;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

if ( main::SLIM_SERVICE ) {
	require SDI::Service::Player::SqueezeNetworkClient;
}

use constant SLIMPROTO_PORT   => 3483;
use constant LATENCY_LIST_MAX => 10;
use constant LATENCY_LIST_MIN => 6;

our @deviceids = (undef, undef, 'squeezebox', 'softsqueeze','squeezebox2','transporter', 'softsqueeze3', 'receiver', 'squeezeslave', 'controller', 'boom', 'softboom', 'squeezeplay');
my $log       = logger('network.protocol.slimproto');
my $faclog    = logger('factorytest');
my $synclog   = logger('player.sync');
my $firmlog   = logger('player.firmware');
my $psdlog    = logger('player.streaming.direct');

if ( main::SLIM_SERVICE ) {
	# SN only allows SB2 or higher to connect
	$deviceids[2] = undef;
}

my $forget_disconnected_time = 60; # disconnected clients will be forgotten unless they reconnect before this

my $check_all_clients_time = 5; # how often to look for disconnected clients
my $check_time;                 # time scheduled for next check_all_clients

if ( main::SLIM_SERVICE ) {
	# don't check as often on SN
	$check_all_clients_time = 30;
	
	# And forget immediately upon disconnect
	$forget_disconnected_time = 5;
}

my $slimproto_socket;

our %ipport;		     # ascii IP:PORT
our %sock2client;	     # reference to client for each sonnected sock
our %heartbeat;          # the last time we heard from a client
our %status;
our %latencyList;        # last few latencies
our %latency;            # current published latency

our %callbacksRAWI;

our %message_handlers = (
	'ANIC' => \&_animation_complete_handler,	# SB2+
	'BODY' => \&_http_body_handler,				# SB2+
	'BUTN' => \&_button_handler,				# SB2+ (TP, Boom)
	'BYE!' => \&_bye_handler,					# SB2+
	'DBUG' => \&_debug_handler,					# SB2+
	'DSCO' => \&_disco_handler,
	'HELO' => \&_hello_handler,
	'IR  ' => \&_ir_handler,
	'KNOB' => \&_knob_handler,					# SB2+ (TP, Boom)
	'META' => \&_http_metadata_handler,			# SB2+
	'RAWI' => \&_raw_ir_handler,
	'RESP' => \&_http_response_handler,
	'SETD' => \&_settings_handler,				# SB2+
	'STAT' => \&_stat_handler,
	'UREQ' => \&_update_request_handler,
	'ALSS' => \&_ambient_light_sensor_handler,
);

sub addHandler {
	my $op = shift;
	my $callbackRef = shift;       
	$message_handlers{$op} = $callbackRef;
}

sub setCallbackRAWI {
	my $callbackRef = shift;
	$callbacksRAWI{$callbackRef} = $callbackRef;
}

sub clearCallbackRAWI {
	my $callbackRef = shift;
	delete $callbacksRAWI{$callbackRef};
}

sub init {
	my $listenerport = SLIMPROTO_PORT;
	
	if ( main::SLIM_SERVICE ) {
		# Let SlimService run on any port
		$listenerport = $main::SLIMPROTO_PORT;
	}

	# Some combinations of Perl / OSes don't define this Macro. Yet it is
	# near constant on all machines. Define if we don't have it.
	eval { my $foo = Socket::IPPROTO_TCP() };

	if ($@) {
		*Socket::IPPROTO_TCP = sub { return 6 };
	}

	$slimproto_socket = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => $main::localClientNetAddr,
		LocalPort => $listenerport,
		Listen    => SOMAXCONN,
		ReuseAddr     => 1,
		Reuse     => 1,
		Timeout   => 0.001
	) || die "Can't listen on port $listenerport for Slim protocol: $!";

	defined(Slim::Utils::Network::blocking($slimproto_socket,0)) || die "Cannot set port nonblocking";

	Slim::Networking::Select::addRead($slimproto_socket, \&slimproto_accept);
	
	# Bug 2707, This timer checks for players that have gone away due to a power loss and disconnects them
	$check_time = time() + $check_all_clients_time;
	Slim::Utils::Timers::setTimer( undef, $check_time, \&check_all_clients );

	$log->info("Squeezebox protocol listening on port $listenerport");
}

sub slimproto_accept {
	my $clientsock = $slimproto_socket->accept();

	return unless $clientsock;

	defined(Slim::Utils::Network::blocking($clientsock,0)) || die "Cannot set port nonblocking";

	# Use the Socket variables this way to silence a warning on perl 5.6
	setsockopt ($clientsock, Socket::IPPROTO_TCP(), Socket::TCP_NODELAY(), 1);

	my $peer;

	if ($clientsock->connected) {

		$peer = $clientsock->peeraddr;

	} else {

		$log->warn("accept failed; not connected.");
		$clientsock->close();
		return;
	}

	if (!$peer) {

		$log->warn("accept failed; couldn't get peer address.");
		$clientsock->close();
		return;
	}
		
	my $tmpaddr = inet_ntoa($peer);

	if (preferences('server')->get('filterHosts') && !(Slim::Utils::Network::isAllowedHost($tmpaddr))) {

		$log->error("unauthorized host, accept denied: $tmpaddr");

		$clientsock->close();
		return;
	}

	$ipport{$clientsock} = join(':', $tmpaddr, $clientsock->peerport);

	Slim::Networking::Select::addRead($clientsock, \&client_readable, 1); # processed during idleStreams
	Slim::Networking::Select::addError($clientsock, \&slimproto_close);

	$log->info("Accepted connection from: [$ipport{$clientsock}]");

	# Set a timer to close the connection if we haven't recieved a HELO in 5 seconds.
	$log->info("Setting timer in 5 seconds to close bogus connection");

	Slim::Utils::Timers::setTimer($clientsock, Time::HiRes::time () + 5, \&slimproto_close, $clientsock);
}

sub check_all_clients {

	my $now = time();

	for my $id ( keys %heartbeat ) {
		
		my $client = Slim::Player::Client::getClient($id) || next;
		
		# skip if we haven't yet heard anything
		if ( !defined $heartbeat{ $client->id } ) {
			$client->requestStatus();
			next;
		}
		
		if ( $log->is_debug ) {
			$log->debug(sprintf("Checking if %s is still alive", $client->id));
		}
		
		# check when we last heard a stat response from the player
		my $last_heard = $now - $heartbeat{ $client->id };
		
		# disconnect client if we haven't heard from it in 3 poll intervals and no time travel
		if ( $last_heard >= $check_all_clients_time * 3 && $now - $check_time <= $check_all_clients_time ) {

			if ( $log->is_info ) {
				$log->info(sprintf("Haven't heard from %s in %d seconds, closing connection",
					$client->id,
					$last_heard,
				));
			}

			slimproto_close( $client->tcpsock );
			next;
		}
		
		# Always ask for status requests so we can use the result for latency tracking
		$client->requestStatus();
	}

	$check_time = $now + $check_all_clients_time;

	Slim::Utils::Timers::setTimer( undef, $check_time, \&check_all_clients );
}

sub slimproto_close {
	my $clientsock = shift;
	my $reconnect  = shift;

	$log->info("connection closed");

	# stop selecting
	Slim::Networking::Select::removeRead($clientsock);
	Slim::Networking::Select::removeError($clientsock);
	Slim::Networking::Select::removeWrite($clientsock);
	Slim::Networking::Select::removeWriteNoBlockQ($clientsock);

	# close socket
	$clientsock->close();

	if ( my $client = $sock2client{$clientsock} ) {
		
		delete $heartbeat{ $client->id };
		delete $latency{ $client };
		delete $latencyList{ $client };

		# If we're closing an old socket for a reconnecting client, we don't
		# need to do any of this disconnect stuff
		if ( !$reconnect ) {
			# check client not forgotten and this is the active slimproto socket for this client
			if ( Slim::Player::Client::getClient( $client->id ) ) {
			
				# notify of disconnect
				Slim::Control::Request::notifyFromArray($client, ['client', 'disconnect']);
			
				unless ($client->controller()->onlyActivePlayer($client)) {
					$client->controller()->playerInactive($client);
				}
			
				# Bug 6714, delete the cached needsUpgrade value, as the player
				# may change firmware versions before coming back
				$client->_needsUpgrade(undef);

				# set timer to forget client
				if ( $forget_disconnected_time ) {
					Slim::Utils::Timers::setTimer($client, time() + $forget_disconnected_time, \&forget_disconnected_client);
				}
				else {
					forget_disconnected_client($client);
				}
			}
		}
	}

	# forget state
	delete($ipport{$clientsock});
	delete($sock2client{$clientsock});
}		

sub forget_disconnected_client {
	my $client = shift;

	$log->info("forgetting disconnected client");

	Slim::Control::Request::executeRequest($client, ['client', 'forget']);
}

sub client_writeable {
	my $clientsock = shift;

	# this prevent the "getpeername() on closed socket" error, which
	# is caused by trying to close the file handle after it's been closed during the
	# read pass but it's still in our writeable list. Don't try to close it twice - 
	# just ignore if it shouldn't exist.
	return unless (defined($ipport{$clientsock})); 
	
	$log->debug("client writeable: " . $ipport{$clientsock});

	if (!($clientsock->connected)) {

		$log->info("connection closed by peer in writeable.");

		slimproto_close($clientsock);		
		return;
	}		
}

sub client_readable {
	my $s = shift;

	if ( !$s->connected ) {

		$log->info("connection closed by peer in readable.");

		slimproto_close($s);		
		return;
	}
	
	while (1) {
		my $nb = sysread( $s, my $buf, 4096 );
		
		if ( defined $nb ) {
			if ( $nb > 0 ) {
				# Parse slimproto frame(s) in packet
				while ( $buf ) {
					my ($op, $len, $data);
					
					# Check for previous partial data
					if ( my $partial = delete ${*$s}{_partial} ) {
						if ( $log->is_debug ) {
							$log->debug( "Client sent additional header / data: " . Data::Dump::dump($buf) );
						}
						
						$buf = $partial . $buf;
					}
					
					# Make sure we have at op and len
					if ( length($buf) < 8 ) {
						if ( $log->is_debug ) {
							$log->debug( "Client sent partial header: " . Data::Dump::dump($buf) );
						}

						${*$s}{_partial} = $buf;

						return;
					}

					$op  = substr $buf, 0, 4;
					$len = unpack 'N', substr( $buf, 4, 4 );

					# Now having read len, make sure that all the data is available
					if ( length($buf) < $len + 8 ) {

						if ( $log->is_debug ) {
							my $partial = substr $buf, 8;
							$log->debug( "Client sent partial data: $op / $len / " . Data::Dump::dump($partial) );
						}

						${*$s}{_partial} = $buf;

						return;

					}

					# Consume op / len from start of buf and read data
					substr $buf, 0, 8, '';
					$data = substr $buf, 0, $len, '';
					
					# Sanity check for bad data
					unless ( length($op) == 4 && defined $len && length($data) == $len ) {
						$log->error( "Client sent bad data: $op / $len / " . length($data) . " data: " . Data::Dump::dump($data) );
						return;
					}
					
					if ( $log->is_debug ) {
						$log->debug( "Slimproto frame: $op, len: $len" );
					}
				
					my $handler_ref = $message_handlers{$op};

					if ( $handler_ref && ref $handler_ref  eq 'CODE' ) {
						my $client = $sock2client{$s};
					
						if ( $op eq 'HELO' ) {
							$handler_ref->( $s, \$data );
						}
						else {
							if ( $client ) {
								$handler_ref->( $client, \$data );
							}
							else {
								$log->error( "client_readable: Client not found for slimproto msg op: $op" );
							}
						}
					}
					else {
						$log->warn("Unknown slimproto op: $op");
					}
				}
				
				return;				
			}
			else {
				$log->info("half-close from client: $ipport{$s}");

				slimproto_close($s);
				return;
			}
		}
		elsif ( $! == EWOULDBLOCK ) {
			next;
		}
		else {
			$log->info( "Error reading from client: $!" );
			
			slimproto_close($s);
			return;
		}
	}
}

# returns the signal strength (0 to 100), outside that range, it's not a wireless connection, so return undef
sub signalStrength {

	my $client = shift;

	if (exists($status{$client}) && ($status{$client}->{'signal_strength'} <= 100)) {
		return $status{$client}->{'signal_strength'};
	} else {
		return undef;
	}
}

sub voltage {
	my $client = shift;
	my $val    = shift;
	
	if ( defined $val && exists $status{$client} ) {
		$status{$client}->{'voltage'} = $val;
	}

	if (exists($status{$client}) && ($status{$client}->{'voltage'} > 0)) {
		return $status{$client}->{'voltage'};
	} else {
		return undef;
	}
}

sub fullness {
	my $client = shift;
	my $value  = shift;
	
	if ( defined $value ) {
		return $status{$client}->{'fullness'} = $value;
	}
	
	return $status{$client}->{'fullness'};
}

# returns how many bytes have been received by the player.  Can be reset to an arbitrary value.
sub bytesReceived {
	my $client = shift;
	return ($status{$client}->{'bytes_received'});
}

sub stop {
	my $client = shift;
	$status{$client}->{'fullness'} = 0;
	$status{$client}->{'rptr'} = 0;
	$status{$client}->{'wptr'} = 0;
	$status{$client}->{'bytes_received_H'} = 0;
	$status{$client}->{'bytes_received_L'} = 0;
	$status{$client}->{'bytes_received'} = 0;
}

sub _ir_handler {
	my $client = shift;
	my $data_ref = shift;

	# format for IR:
	# [4]   time since startup in ticks (1KHz)
	# [1]	code format
	# [1]	number of bits 
	# [4]   the IR code, up to 32 bits      
	if (length($$data_ref) != 10) {

		if ( $log->is_warn ) {
			$log->warn("bad length ". length($$data_ref) . " for IR. Ignoring");
		}
		
		return;
	}

	my ($irTime, $irCode) = unpack('NxxH8', $$data_ref);

	Slim::Hardware::IR::enqueue($client, $irCode, $irTime) if $client->irenable();

	if ( $faclog->is_debug ) {
		$faclog->debug(sprintf("FACTORYTEST\tevent=ir\tmac=%s\tcode=%s", $client->id, $irCode));
	}
}

sub _raw_ir_handler {
	my $client = shift;
	my $data_ref = shift;

	if ( $log->is_info ) {
		$log->info("Raw IR, " . (length($$data_ref)/4)."samples");
	}

	no strict 'refs';

	foreach my $callbackRAWI (keys %callbacksRAWI) {

		$callbackRAWI = $callbacksRAWI{$callbackRAWI};
		&$callbackRAWI( $client, $$data_ref);
	}
}

sub _ambient_light_sensor_handler {
	my $client = shift;
	my $data_ref = shift;
	my ($packet_rev, $time, $lux, $channel_0, $channel_1) = unpack("CNNnn", $$data_ref);
	# print "ALS: $time, $lux, $channel_0, $channel_1\n";
	# Do something with the Ambient lightsensor data here.
}

sub _http_response_handler {
	my $client = shift;
	my $data_ref = shift;

	# HTTP stream headers
	if ( $log->is_info ) {
		$log->info("Squeezebox got HTTP response:\n$$data_ref");
	}

	if ($client->can('directHeaders')) {
		$client->directHeaders($$data_ref);
	}

}

sub _debug_handler {
	my $client = shift;
	my $data_ref = shift;

	if ( $firmlog->is_info ) {
		$firmlog->info(sprintf("[%s] %s", $client->id, $$data_ref));
	}
}

sub _disco_handler {
	my $client = shift;
	my $data_ref = shift;
	
	# disconnection reasons
	my %reasons = (
		0 => 'Connection closed normally',              # TCP_CLOSE_FIN
		1 => 'Connection reset by local host',          # TCP_CLOSE_LOCAL_RST
		2 => 'Connection reset by remote host',         # TCP_CLOSE_REMOTE_RST
		3 => 'Connection is no longer able to work',    # TCP_CLOSE_UNREACHABLE
		4 => 'Connection timed out',                    # TCP_CLOSE_LOCAL_TIMEOUT
	);
	
	my $reason = unpack('C', $$data_ref);

	$log->info("Squeezebox got disconnection on the data channel: $reasons{$reason}");
	
	# SN may want to log connection errors
	if ( main::SLIM_SERVICE ) {
		if ( $reason > 0 ) {
			$client->logStreamEvent( 'disconnect', { reason => $reasons{$reason} } );
		}
	}

	if ($reason
	
		# bug 10475
		# Sometimes the player sends a DSCO with a non-zero reason code
		# when it would seem that a normal disconnect at the end of the track
		# is what has really happened. Quite why has not yet been determined.
		# It would seem, from reports that this problem happens with both ip3k
		# players and SqueezePlay, so it is probably something triggered by SC.
		# It does not seem to be confined to a single operating-system platform.
		#
		# We ignore this non-zero code if our Controller is already in STREAMOUT
		# state (which will only be the case for local tracks)
		
		&& !$client->controller->isStreamout()
		
		)
	{
		# Report failure via protocol handler if available
		my $controller = $client->controller()->songStreamController();
		if ($controller && $controller->isDirect() ) {
			my $handler = $controller->protocolHandler();
			if ($handler->can("handleDirectError") ) {
				
				# bug 10407 - make sure ready to stream again
				$client->readyToStream(1);
				
				$handler->handleDirectError( $client, $controller->streamUrl(), $reason, $reasons{$reason} );
				return;
			}
		}
		
		$client->failedDirectStream( $reasons{$reason} );
	} else {
		
		if ($reason) {
			$log->warn('Unexpected data stream disconnect type: ', $reasons{$reason});
		}
		
		$client->statHandler('EoS');
	}
}

sub _http_body_handler {
	my $client = shift;
	my $data_ref = shift;

	$log->info("Squeezebox got body response");

	if ($client->can('directBodyFrame')) {
		$client->directBodyFrame($$data_ref);
	}
}
	
sub _stat_handler {
	my $client = shift;
	my $data_ref = shift;
	
	my $now = Time::HiRes::time();
	
	# Bug 3881, 6350, ignore stat response if player is not in the heartbeat
	# list, i.e. it is upgrading firmware
	if ( !exists $heartbeat{ $client->id } ) {
		$log->debug( 'Ignoring stat response, player ' . $client->id . ' is not in heartbeat list' );
		return;
	}
	
	# update the heartbeat value for this player
	$heartbeat{ $client->id } = $now;

	#struct status_struct {
	#        u32_t event;
	#        u8_t num_crlf;          // number of consecutive cr|lf received while parsing headers
	#        u8_t mas_initialized;   // 'm' or 'p'
	#        u8_t mas_mode;          // serdes mode
	#        u32_t rptr;
	#        u32_t wptr;
	#        u64_t bytes_received;
	#		 u16_t signal_strength;
	#        u32_t jiffies;
	#        u32_t output_buffer_size;
	#        u32_t output_buffer_fullness;
	#        u32_t elapsed_seconds;
	#        u16_t voltage;
	#        u32_t elapsed_milliseconds;
	#        u32_t server_timestamp;
	#        u16_t error_code;
	#
	
	# event types:
	# 	vfdc - vfd received
	#   i2cc - i2c command recevied
	#	STMa - AUTOSTART    
	#	STMc - CONNECT      
	#	STMe - ESTABLISH    
	#	STMf - CLOSE        
	#	STMh - ENDOFHEADERS 
	#	STMp - PAUSE        
	#	STMr - UNPAUSE           // "resume"
	#	STMt - TIMER        
	#	STMu - UNDERRUN     
	#	STMl - FULL		// triggers start of synced playback
	#	STMd - DECODE_READY	// decoder has no more data
	#	STMs - TRACK_STARTED	// a new track started playing
	#	STMn - NOT_SUPPORTED	// decoder does not support the track format
	
	#   STMz - pseudo-status defived from DSCO meaning end-of-stream

	my ($fullnessA, $fullnessB);
	
	(	$status{$client}->{'event_code'},
		$status{$client}->{'num_crlf'},
		$status{$client}->{'mas_initialized'},
		$status{$client}->{'mas_mode'},
		$fullnessA,
		$fullnessB,
		$status{$client}->{'bytes_received_H'},
		$status{$client}->{'bytes_received_L'},
		$status{$client}->{'signal_strength'},
		$status{$client}->{'jiffies'},
		$status{$client}->{'output_buffer_size'},
		$status{$client}->{'output_buffer_fullness'},
		$status{$client}->{'elapsed_seconds'},
		$status{$client}->{'voltage'},
		$status{$client}->{'elapsed_milliseconds'},
		$status{$client}->{'server_timestamp'},
		$status{$client}->{'error_code'},
	) = unpack ('a4CCCNNNNnNNNNnNNn', $$data_ref);
	
	if ( length($$data_ref) != 57 ) {
		# Older firmware that doesn't report error_code
		$status{$client}->{'error_code'} = 0;
	}
		
	# Track latency if we have a server timestamp
	if ( $status{$client}->{'server_timestamp'} ) {
		my $latency = (int($now * 1000 % 0xffffffff) - $status{$client}->{'server_timestamp'}) / 2;
	
		push (@{$latencyList{$client}}, $latency) if ($latency >= 0 && $latency < 1000);
		shift(@{$latencyList{$client}}) if (@{$latencyList{$client}} > LATENCY_LIST_MAX);

		$latency{$client} = Math::VecStat::min($latencyList{$client}) if (@{$latencyList{$client}} >= LATENCY_LIST_MIN);
		
		if ( $log->is_debug ) {
			$log->debug(
				$client->id() . " latency=$latency{$client}, from ("
				. join(', ', @{$latencyList{$client}}) . ')'
			);
		}
	}	
		
	$client->trackJiffiesEpoch($status{$client}->{'jiffies'}, $now);

	$status{$client}->{'bytes_received'} = $status{$client}->{'bytes_received_H'} * 2**32 + $status{$client}->{'bytes_received_L'}; 

	if ($client->model() eq 'squeezebox' &&
		$client->revision() < 20 && $client->revision() > 0) {
		$client->bufferSize(262144);
		$status{$client}->{'rptr'} = $fullnessA;
		$status{$client}->{'wptr'} = $fullnessB;

		my $fullness = $status{$client}->{'wptr'} - $status{$client}->{'rptr'};
		if ($fullness < 0) {
			$fullness = $client->bufferSize() + $fullness;
		};
		$status{$client}->{'fullness'} = $fullness;
	} else {
		$client->bufferSize($fullnessA);
		$status{$client}->{'fullness'} = $fullnessB;
	}
	
	# Use milliseconds for the song-elapsed-time if defined and have not suffered truncation
	if (defined $status{$client}->{'elapsed_milliseconds'}) {
		my $songElapsed = $status{$client}->{'elapsed_milliseconds'} / 1000;
		if ($songElapsed < $status{$client}->{'elapsed_seconds'}) {
			$songElapsed = $status{$client}->{'elapsed_seconds'};
		}
		$client->songElapsedSeconds($songElapsed);
	}

	if (defined($status{$client}->{'output_buffer_fullness'})) {

		$client->outputBufferFullness($status{$client}->{'output_buffer_fullness'});
	}

	$::perfmon && ($client->isPlaying()) && $client->bufferFullnessLog()->log($client->usage()*100);
	$::perfmon && ($status{$client}->{'signal_strength'} <= 100) &&
		$client->signalStrengthLog()->log($status{$client}->{'signal_strength'});
	
	if ( $faclog->is_debug ) {
		$faclog->debug(sprintf("FACTORYTEST\tevent=stat\tmac=%s\tsignalstrength=%s",
			$client->id, $status{$client}->{'signal_strength'}
		));
	}
	
	if ($log->is_info) {
		$log->info(sprintf("%s: STAT-%s: fullness=%d, output_fullness=%d, elapsed=%.3f",
			$client->id(), $status{$client}->{'event_code'}, $status{$client}->{'fullness'},
			$status{$client}->{'output_buffer_fullness'} || -1,
			defined($status{$client}->{'elapsed_milliseconds'}) ? $status{$client}->{'elapsed_milliseconds'} /1000 : -1  ))
	}

	if ($log->is_debug) {

		my $msg = join("\n", 
			$client->id() . " Squeezebox stream status:",
			"\tevent_code:      $status{$client}->{'event_code'}",
			#"\tnum_crlf:        $status{$client}->{'num_crlf'}",
			#"\tmas_initiliazed: $status{$client}->{'mas_initialized'}",
			#"\tmas_mode:        $status{$client}->{'mas_mode'}",
			"\tbytes_rec_H      $status{$client}->{'bytes_received_H'}",
			"\tbytes_rec_L      $status{$client}->{'bytes_received_L'}",
			"\tfullness:        $status{$client}->{'fullness'} (" . int($status{$client}->{'fullness'}/$client->bufferSize()*100) . "%)",
			"\tbufferSize      " . $client->bufferSize,
			"\tfullness         $status{$client}->{'fullness'}",
			"\tbytes_received   $status{$client}->{'bytes_received'}",
			"\tsignal_strength: $status{$client}->{'signal_strength'}",
			"\tjiffies:         $status{$client}->{'jiffies'}",
			"\tvoltage:         $status{$client}->{'voltage'}",
			""
		);

		$log->debug($msg);

		if (defined($status{$client}->{'output_buffer_size'})) {

			my $msg = join("\n",
				"",
				"\toutput size:     $status{$client}->{'output_buffer_size'}",
				"\toutput fullness: $status{$client}->{'output_buffer_fullness'}",
				"\telapsed seconds: $status{$client}->{'elapsed_seconds'}",
				"",
			);

			$log->debug($msg);
		}
		
		if (defined($status{$client}->{'elapsed_milliseconds'})) {
			
			my $msg = join("\n",
				"",
				"\telapsed milliseconds: $status{$client}->{'elapsed_milliseconds'}",
				"\tserver timestamp:     $status{$client}->{'server_timestamp'}",
				"",
			);
			
			$log->debug($msg);
		}
	}
	
	if ($client->isSynced(1) && $client->isPlaying(1) && $client->needsWeightedPlayPoint()) {
		my $statusTime = $client->jiffiesToTimestamp( $status{$client}->{'jiffies'} );
		my $apparentStreamStartTime;
		if ($status{$client}->{'elapsed_milliseconds'}) {
			$apparentStreamStartTime = $statusTime - ($status{$client}->{'elapsed_milliseconds'} / 1000);
		} else {
			$apparentStreamStartTime = $client->apparentStreamStartTime($statusTime);
		}
		if ($apparentStreamStartTime) {
			$client->publishPlayPoint( $statusTime, $apparentStreamStartTime, undef );
		}
	}
	
	$client->statHandler($status{$client}->{'event_code'}, $status{$client}->{'jiffies'}, $status{$client}->{'error_code'});

	if ( main::SLIM_SERVICE ) {
		# Bug 8995, Update signal strength on SN
		if ( !$client->playerData->signal ) {
			$client->playerData->signal( $status{$client}->{signal_strength} );
			$client->playerData->update;
		}
	}
}

sub getLatency {
	return $latency{shift} || 0;
}

sub getPlayPointData {
	my $client = shift;
	return ($status{$client}->{'jiffies'}, $status{$client}->{'elapsed_milliseconds'});
}
	
sub _update_request_handler {
	my $client = shift;
	my $data_ref = shift;

	# THIS IS ONLY FOR SDK5.X-BASED FIRMWARE OR LATER
	$log->info("Client requests firmware update.");

	$client->unblock();
	Slim::Hardware::IR::forgetQueuedIR($client);
	
	# Bug 3881, stop watching this client
	delete $heartbeat{ $client->id };
	
	# On SN, if the player requests a firmware update, send the latest version available
	# not just the current version as SlimServer does
	if ( main::SLIM_SERVICE ) {
		# Wipe cached needsUpgrade value
		$client->_needsUpgrade(undef);
		
		if ( $client->deviceid == 10 && $client->revision >= 30 ) {
			# Special case, Boom 2-stage upgrade can't use 1, must use 30 as lowest
			$client->revision(30);
		}
		else {
			# Set client revision to 1 to force an upgrade
			$client->revision(1);
		}
	}
	
	$client->upgradeFirmware();
}
	
sub _animation_complete_handler {
	my $client = shift;
	my $data_ref = shift;

	$client->display->clientAnimationComplete();
}

sub _http_metadata_handler {
	my $client = shift;
	my $data_ref = shift;

	if ( $psdlog->is_info ) {
		$psdlog->info("metadata (len: ". length($$data_ref) .")");
	}

	if ($client->can('directMetadata')) {
		$client->directMetadata($$data_ref);
	}
}

sub _bye_handler {
	my $client = shift;
	my $data_ref = shift;

	# THIS IS ONLY FOR THE OLD SDK4.X UPDATER
	$log->info("Saying goodbye");

	if ($$data_ref eq chr(1)) {

		$log->info("Going out for upgrade...");

		# give the player a chance to get into upgrade mode
		sleep(2);
		$client->unblock();
		$client->upgradeFirmware();
	}
} 

sub _hello_handler {
	my $s = shift;
	my $data_ref = shift;
	
	# killing timer once we get a valid hello 	 
	$log->info("Killing bogus player timer."); 	 
 
	Slim::Utils::Timers::killOneTimer($s, \&slimproto_close);

	my ($deviceid, $revision, @mac, $uuid, $bitmapped, $reconnect, $wlan_channellist, $bytes_received_H, $bytes_received_L, $bytes_received, $lang);

	# Newer player fw reports a uuid. With uuid, length is 36; without uuid, length is 20
	my $data_ref_length = length( $$data_ref);

	if( $data_ref_length == 36) {
		(	$deviceid, $revision, 
			$mac[0], $mac[1], $mac[2], $mac[3], $mac[4], $mac[5], $uuid,
			$wlan_channellist, $bytes_received_H, $bytes_received_L, $lang
		) = unpack("CCH2H2H2H2H2H2H32nNNA2", $$data_ref);
	} else {
		(	$deviceid, $revision, 
			$mac[0], $mac[1], $mac[2], $mac[3], $mac[4], $mac[5],
			$wlan_channellist, $bytes_received_H, $bytes_received_L, $lang
		) = unpack("CCH2H2H2H2H2H2nNNA2", $$data_ref);
	}

	$bitmapped = $wlan_channellist & 0x8000;
	$reconnect = $wlan_channellist & 0x4000;
	$wlan_channellist = sprintf('%04x', $wlan_channellist & 0x3fff);

	if (defined($bytes_received_H)) {
		$bytes_received = $bytes_received_H * 2**32 + $bytes_received_L; 
	}

	my $mac = join(':', @mac);
	my $id  = $mac;

	if ($log->is_info) {

		$log->info(join(' ', 
			"Squeezebox says hello: ",
			"Deviceid: $deviceid",
			"revision: $revision",
			"mac: $mac",
			"uuid: " . ( $uuid || 'not available' ),
			"bitmapped: $bitmapped",
			"reconnect: $reconnect",
			"wlan_channellist: $wlan_channellist",
			"lang: $lang",
		));

		if (defined($bytes_received)) {

			$log->info("Squeezebox also says: bytes_received: $bytes_received");
		}
	}

	if ( $faclog->is_debug ) {
		$faclog->debug(sprintf("FACTORYTEST\tevent=helo\tmac=%s\tdeviceid=%s\trevision=%s\ttwlan_channellist=%s",
			$mac, $deviceid, $revision, $wlan_channellist
		));
	}

	# sanity check on socket
	if (!$s->peerport || !$s->peeraddr) {
		return;
	}
	
	my $paddr  = sockaddr_in($s->peerport, $s->peeraddr);
	my $client = Slim::Player::Client::getClient($id); 

	my ($client_class, $display_class);

	if (!defined($deviceids[$deviceid])) {

		$log->info("unknown device id $deviceid in HELO frame! Closing connection.");

		my $frame = pack('n', 4) . 'dsco';
		Slim::Networking::Select::writeNoBlock( $s, \$frame);
		slimproto_close($s);
		return;

	} elsif ($deviceids[$deviceid] eq 'squeezebox2') {

		$client_class  = 'Slim::Player::Squeezebox2';
		$display_class = 'Slim::Display::Squeezebox2';

	} elsif ($deviceids[$deviceid] eq 'receiver') {

		$client_class  = 'Slim::Player::Receiver';
		$display_class = 'Slim::Display::NoDisplay';

	} elsif ($deviceids[$deviceid] eq 'boom') {

		$client_class  = 'Slim::Player::Boom';
		$display_class = 'Slim::Display::Boom';

	} elsif ($deviceids[$deviceid] eq 'transporter') {

		$client_class  = 'Slim::Player::Transporter';
		$display_class = 'Slim::Display::Transporter';

	} elsif ($deviceids[$deviceid] eq 'squeezebox') {	

		$client_class  = 'Slim::Player::Squeezebox1';

		if ($bitmapped) {

			$display_class = 'Slim::Display::SqueezeboxG';

		} else {

			$display_class = 'Slim::Display::Text';
		}
		
		# Load SB1 hardware module only if needed
		require Slim::Hardware::mas35x9;

	} elsif ($deviceids[$deviceid] eq 'softsqueeze') {

		$client_class  = 'Slim::Player::SoftSqueeze';
		$display_class = 'Slim::Display::Squeezebox2';

	} elsif ($deviceids[$deviceid] eq 'softsqueeze3') {

		$client_class = 'Slim::Player::SoftSqueeze';
		$display_class = 'Slim::Display::Transporter';

	} elsif ($deviceids[$deviceid] eq 'softboom') {

		$client_class = 'Slim::Player::SoftSqueeze';
		$display_class = 'Slim::Display::Boom';

	} elsif ($deviceids[$deviceid] eq 'squeezeslave') {

		$client_class = 'Slim::Player::SqueezeSlave';
		$display_class = 'Slim::Display::NoDisplay';

	} elsif ($deviceids[$deviceid] eq 'controller') {

		$client_class  = 'Slim::Player::Controller';
		$display_class = 'Slim::Display::NoDisplay';

	} elsif ($deviceids[$deviceid] eq 'squeezeplay') {

		$client_class  = 'Slim::Player::SqueezePlay';
		$display_class = 'Slim::Display::NoDisplay';

	} else {

		$log->info("Unknown device type for $deviceid in HELO frame! Closing connection");

		my $frame = pack('n', 4) . 'dsco';
		Slim::Networking::Select::writeNoBlock( $s, \$frame);
		slimproto_close($s);
		return;
	}
	
	if ( main::SLIM_SERVICE ) {		
		# SqueezeNetwork clients use a different client class
		# Note: Other player classes use SNClient directly
		if ( $client_class eq 'Slim::Player::Squeezebox2' ) {
			$client_class = 'SDI::Service::Player::SqueezeNetworkClient';
		}
	}

	if (defined $client && blessed($client) && blessed($client) ne $client_class) {

		$log->info("Forgetting client, it is not a $client_class");

		$client->forgetClient();

		$client = undef;
	}

	if (defined $client && blessed($client->display) && blessed($client->display) ne $display_class) {
		$log->info("Change display for $client_class to $display_class");
		$client->display->forgetDisplay();

		Slim::bootstrap::tryModuleLoad($display_class);

		if ($@) {
			$log->logBacktrace;
			$log->logdie("FATAL: Couldn't load module: $display_class: [$@]");
		}

		$client->display( $display_class->new($client) );
		$client->display->init;
	}

	if (!defined($client)) {

		$log->info("Creating new client, id: $id ipport: $ipport{$s}");

		Slim::bootstrap::tryModuleLoad($client_class);

		if ($@) {
			$log->logBacktrace;
			$log->logdie("FATAL: Couldn't load module: $client_class: [$@]");
		}

		$client = $client_class->new(
			$id,        # mac
			$paddr,     # sockaddr_in
			$revision,  # rev
			$s,         # tcp sock
			$deviceid,  # device ID
			$uuid,      # UUID (if available)
		);

		Slim::bootstrap::tryModuleLoad($display_class);

		if ($@) {
			$log->logBacktrace;
			$log->logdie("FATAL: Couldn't load module: $display_class: [$@]");
		}
		
		# Set default language from firmware language on SN
		if ( main::SLIM_SERVICE && !preferences('server')->client($client)->get('language')) {
			preferences('server')->client($client)->set( language => $lang );
		}

		$client->display( $display_class->new($client) );

		$client->macaddress($mac);
		$client->init;
		$client->reconnect($paddr, $revision, $s, 0);  # don't "reconnect" if the player is new.

	} else {

		$log->info("Hello from existing client: $id on ipport: $ipport{$s}");

		my $oldsock = $client->tcpsock();

		if (defined($oldsock) && exists($sock2client{$oldsock})) {
		
			if ( $log->is_info ) {
				$log->info("Closing previous socket to client: $id on ipport: ".
					join(':', inet_ntoa($oldsock->peeraddr), $oldsock->peerport)
				);
			}

			slimproto_close( $client->tcpsock, 'reconnect' );
		}

		Slim::Utils::Timers::killTimers($client, \&forget_disconnected_client);
		
		# Reset isUpgrading flag now that the player has come back
		$client->isUpgrading(0);

		$client->reconnect($paddr, $revision, $s, $reconnect, $bytes_received);

		# notify of reconnect
		Slim::Control::Request::notifyFromArray($client, ['client', 'reconnect']);

	}

	$sock2client{$s} = $client;
	
	$latencyList{$client} = [];
	
	# Bug 10634 - reset the jiffiesEpoch so that any drift during a long disconnection is reset immediately
	$client->jiffiesEpoch(undef);
	
	# add the player to the list of clients we're watching for signs of life
	$heartbeat{ $client->id } = Time::HiRes::time();
	
	if ( main::SLIM_SERVICE ) {
		# Bug 6979, if this is a Ray and is on the same account as an MP Jive,
		# workaround short timeout issue by not updating firmware yet
		if ( $client->deviceid == 7 && $client->needsUpgrade ) {
			
			# workaround to handle multiple firmware versions causing blocking modes to stack
			while (Slim::Buttons::Common::mode($client) eq 'block') {
				$client->unblock();
			}

			# make sure volume is set, without changing temp setting
			$client->audio_outputs_enable($client->power());
			$client->volume($client->volume(), defined($client->tempVolume()));
			
			# There is a possible race condition between when jived links a new Ray to Jive
			# and when the Ray connects to SN, so we want to impose a bit of a delay here before checking
			# if we should do a firmware update.
			Slim::Utils::Timers::setTimer(
				undef,
				time() + 3,
				sub {
					my $jives = $client->playerData->active_jives();
			
					if ( $firmlog->is_debug ) {
						$firmlog->debug(
							"Ray needs upgrade, active jives: " . Data::Dump::dump($jives)
						)
					}
			
					for my $jive ( @{$jives} ) {
						if ( $jive->{rev} =~ /r(?:1220|1425)$/ ) { # MP firmware
							$firmlog->debug('Not updating Ray, MP Jive is connected');
							return;
						}
					}
					
					# Tell Ray to update now, unless we're already updating
					if ( $client->revision != 1 ) {
						$client->execute( [ 'stop' ] );
						$client->sendFrame('ureq');
					}
				},
			);
			
			return;			
		}
	}

	if ($client->needsUpgrade()) {

		# don't start playing if we're upgrading
		$client->execute(['stop']);

		# ask for an update if the player will do it automatically
		$client->sendFrame('ureq');

		$client->brightness($client->maxBrightness());

		# turn of visualizers and screen2 display
		$client->modeParam('visu', [0]);
		$client->modeParam('screen2active', undef);
		
		$client->controller()->playerInactive($client);
		
		$client->block( {
			'screen1' => {
				'line' => [
					$client->string('PLAYER_NEEDS_UPGRADE_1'),
					$client->isa('Slim::Player::Boom') ? '' : $client->string('PLAYER_NEEDS_UPGRADE_2')
				],
				'fonts' => { 
					'graphic-320x32' => 'light',
					'graphic-160x32' => 'light_n',
					'graphic-280x16' => 'small',
					'text'           => 2,
				}
			},
			'screen2' => {},
		}, 'upgrade');

	} else {

		# workaround to handle multiple firmware versions causing blocking modes to stack
		while (Slim::Buttons::Common::mode($client) eq 'block') {
			$client->unblock();
		}

		# make sure volume is set, without changing temp setting
		$client->audio_outputs_enable($client->power());
		$client->volume($client->volume(), defined($client->tempVolume()));
	}
}

sub _button_handler {
	my $client = shift;
	my $data_ref = shift;

	# handle hard buttons
	my ($time, $button) = unpack( 'NH8', $$data_ref);

	Slim::Hardware::IR::enqueue($client, $button, $time);

	$log->info("Hard button: $button time: $time");
} 

sub _knob_handler {
	my $client = shift;
	my $data_ref = shift;

	# handle knob movement
	my ($time, $position, $sync) = unpack('NNC', $$data_ref);

	# Perl doesn't have an unsigned network long format.
	if ($position & 1 << 31) {
		$position = -($position & 0x7FFFFFFF);
	}

	my $oldPos   = $client->knobPos();
	my $knobSync = $client->knobSync();

	if ($knobSync != $sync) {

		$log->info("Stale knob sync code: $position (old: $oldPos) time: $time sync: $sync");
		return;
	}

	if ( $log->is_info ) {
		$log->info(sprintf("knob position: $position (old: %s) time: $time\n", defined $oldPos ? $oldPos : 'undef'));
	}

	$client->knobPos($position);
	$client->knobTime($time);
	
	# Bug 3545: Remote IR sometimes registers an irhold time. Since the
	# Knob doesn't work on repeat timers, we have to reset it here to
	# reactivate control of Slim::Buttons::Common::scroll by the knob
	Slim::Hardware::IR::resetHoldStart($client);

	Slim::Hardware::IR::executeButton($client, 'knob', $time, undef, 1);

	$client->sendFrame('knoa');
}

sub _settings_handler {
	my $client = shift;
	my $data_ref = shift;

	if ($client->can('directBodyFrame')) {
		$client->playerSettingsFrame($data_ref);
	}
}

1;
